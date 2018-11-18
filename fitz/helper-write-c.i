%{
void pdf_dict_put_val_null(fz_context *ctx, pdf_obj *obj, int idx);

#include <assert.h>
#include <limits.h>
#include <string.h>

#define SIG_EXTRAS_SIZE (1024)

typedef struct pdf_write_state_s pdf_write_state;

/*
    As part of linearization, we need to keep a list of what objects are used
    by what page. We do this by recording the objects used in a given page
    in a page_objects structure. We have a list of these structures (one per
    page) in the page_objects_list structure.

    The page_objects structure maintains a heap in the object array, so
    insertion takes log n time, and we can heapsort and dedupe at the end for
    a total worse case n log n time.

    The magic heap invariant is that:
        entry[n] >= entry[(n+1)*2-1] & entry[n] >= entry[(n+1)*2]
    or equivalently:
        entry[(n-1)>>1] >= entry[n]

    For a discussion of the heap data structure (and heapsort) see Kingston,
    "Algorithms and Data Structures".
*/

typedef struct {
    int num_shared;
    int page_object_number;
    int num_objects;
    int min_ofs;
    int max_ofs;
    /* Extensible list of objects used on this page */
    int cap;
    int len;
    int object[1];
} page_objects;

typedef struct {
    int cap;
    int len;
    page_objects *page[1];
} page_objects_list;

struct pdf_write_state_s
{
    fz_output *out;

    int do_incremental;
    int do_tight;
    int do_ascii;
    int do_expand;
    int do_compress;
    int do_compress_images;
    int do_compress_fonts;
    int do_garbage;
    int do_linear;
    int do_clean;

    int list_len;
    int *use_list;
    int64_t *ofs_list;
    int *gen_list;
    int *renumber_map;
    int continue_on_error;
    int *errors;
    /* The following extras are required for linearization */
    int *rev_renumber_map;
    int start;
    int64_t first_xref_offset;
    int64_t main_xref_offset;
    int64_t first_xref_entry_offset;
    int64_t file_len;
    int hints_shared_offset;
    int hintstream_len;
    pdf_obj *linear_l;
    pdf_obj *linear_h0;
    pdf_obj *linear_h1;
    pdf_obj *linear_o;
    pdf_obj *linear_e;
    pdf_obj *linear_n;
    pdf_obj *linear_t;
    pdf_obj *hints_s;
    pdf_obj *hints_length;
    int page_count;
    page_objects_list *page_object_lists;
    int crypt_object_number;
};

/*
 * Constants for use with use_list.
 *
 * If use_list[num] = 0, then object num is unused.
 * If use_list[num] & PARAMS, then object num is the linearisation params obj.
 * If use_list[num] & CATALOGUE, then object num is used by the catalogue.
 * If use_list[num] & PAGE1, then object num is used by page 1.
 * If use_list[num] & SHARED, then object num is shared between pages.
 * If use_list[num] & PAGE_OBJECT then this must be the first object in a page.
 * If use_list[num] & OTHER_OBJECTS then this must should appear in section 9.
 * Otherwise object num is used by page (use_list[num]>>USE_PAGE_SHIFT).
 */
enum
{
    USE_CATALOGUE = 2,
    USE_PAGE1 = 4,
    USE_SHARED = 8,
    USE_PARAMS = 16,
    USE_HINTS = 32,
    USE_PAGE_OBJECT = 64,
    USE_OTHER_OBJECTS = 128,
    USE_PAGE_MASK = ~255,
    USE_PAGE_SHIFT = 8
};

/*
 * page_objects and page_object_list handling functions
 */
static page_objects_list *
page_objects_list_create(fz_context *ctx)
{
    page_objects_list *pol = fz_calloc(ctx, 1, sizeof(*pol));

    pol->cap = 1;
    pol->len = 0;
    return pol;
}

static void
page_objects_list_destroy(fz_context *ctx, page_objects_list *pol)
{
    int i;

    if (!pol)
        return;
    for (i = 0; i < pol->len; i++)
    {
        fz_free(ctx, pol->page[i]);
    }
    fz_free(ctx, pol);
}

static void
page_objects_list_ensure(fz_context *ctx, page_objects_list **pol, int newcap)
{
    int oldcap = (*pol)->cap;
    if (newcap <= oldcap)
        return;
    *pol = fz_resize_array(ctx, *pol, 1, sizeof(page_objects_list) + (newcap-1)*sizeof(page_objects *));
    memset(&(*pol)->page[oldcap], 0, (newcap-oldcap)*sizeof(page_objects *));
    (*pol)->cap = newcap;
}

static page_objects *
page_objects_create(fz_context *ctx)
{
    int initial_cap = 8;
    page_objects *po = fz_calloc(ctx, 1, sizeof(*po) + (initial_cap-1) * sizeof(int));

    po->cap = initial_cap;
    po->len = 0;
    return po;
}

static void
page_objects_insert(fz_context *ctx, page_objects **ppo, int i)
{
    page_objects *po;

    /* Make a page_objects if we don't have one */
    if (*ppo == NULL)
        *ppo = page_objects_create(ctx);

    po = *ppo;
    /* page_objects insertion: extend the page_objects by 1, and put us on the end */
    if (po->len == po->cap)
    {
        po = fz_resize_array(ctx, po, 1, sizeof(page_objects) + (po->cap*2 - 1)*sizeof(int));
        po->cap *= 2;
        *ppo = po;
    }
    po->object[po->len++] = i;
}

static void
page_objects_list_insert(fz_context *ctx, pdf_write_state *opts, int page, int object)
{
    page_objects_list_ensure(ctx, &opts->page_object_lists, page+1);
    if (opts->page_object_lists->len < page+1)
        opts->page_object_lists->len = page+1;
    page_objects_insert(ctx, &opts->page_object_lists->page[page], object);
}

static void
page_objects_list_set_page_object(fz_context *ctx, pdf_write_state *opts, int page, int object)
{
    page_objects_list_ensure(ctx, &opts->page_object_lists, page+1);
    opts->page_object_lists->page[page]->page_object_number = object;
}

static void
page_objects_sort(fz_context *ctx, page_objects *po)
{
    int i, j;
    int n = po->len;

    /* Step 1: Make a heap */
    /* Invariant: Valid heap in [0..i), unsorted elements in [i..n) */
    for (i = 1; i < n; i++)
    {
        /* Now bubble backwards to maintain heap invariant */
        j = i;
        while (j != 0)
        {
            int tmp;
            int k = (j-1)>>1;
            if (po->object[k] >= po->object[j])
                break;
            tmp = po->object[k];
            po->object[k] = po->object[j];
            po->object[j] = tmp;
            j = k;
        }
    }

    /* Step 2: Heap sort */
    /* Invariant: valid heap in [0..i), sorted list in [i..n) */
    /* Initially: i = n */
    for (i = n-1; i > 0; i--)
    {
        /* Swap the maximum (0th) element from the page_objects into its place
         * in the sorted list (position i). */
        int tmp = po->object[0];
        po->object[0] = po->object[i];
        po->object[i] = tmp;
        /* Now, the page_objects is invalid because the 0th element is out
         * of place. Bubble it until the page_objects is valid. */
        j = 0;
        while (1)
        {
            /* Children are k and k+1 */
            int k = (j+1)*2-1;
            /* If both children out of the page_objects, we're done */
            if (k > i-1)
                break;
            /* If both are in the page_objects, pick the larger one */
            if (k < i-1 && po->object[k] < po->object[k+1])
                k++;
            /* If j is bigger than k (i.e. both of its children),
             * we're done */
            if (po->object[j] > po->object[k])
                break;
            tmp = po->object[k];
            po->object[k] = po->object[j];
            po->object[j] = tmp;
            j = k;
        }
    }
}

static int
order_ge(int ui, int uj)
{
    /*
    For linearization, we need to order the sections as follows:

        Remaining pages                    (Part 7)
        Shared objects                    (Part 8)
        Objects not associated with any page        (Part 9)
        Any "other" objects
                            (Header)(Part 1)
        (Linearization params)                (Part 2)
                    (1st page Xref/Trailer)    (Part 3)
        Catalogue (and other document level objects)    (Part 4)
        First page                    (Part 6)
        (Primary Hint stream)            (*)    (Part 5)
        Any free objects

    Note, this is NOT the same order they appear in
    the final file!

    (*) The PDF reference gives us the option of putting the hint stream
    after the first page, and we take it, for simplicity.
    */

    /* If the 2 objects are in the same section, then page object comes first. */
    if (((ui ^ uj) & ~USE_PAGE_OBJECT) == 0)
        return ((ui & USE_PAGE_OBJECT) == 0);
    /* Put unused objects last */
    else if (ui == 0)
        return 1;
    else if (uj == 0)
        return 0;
    /* Put the hint stream before that... */
    else if (ui & USE_HINTS)
        return 1;
    else if (uj & USE_HINTS)
        return 0;
    /* Put page 1 before that... */
    else if (ui & USE_PAGE1)
        return 1;
    else if (uj & USE_PAGE1)
        return 0;
    /* Put the catalogue before that... */
    else if (ui & USE_CATALOGUE)
        return 1;
    else if (uj & USE_CATALOGUE)
        return 0;
    /* Put the linearization params before that... */
    else if (ui & USE_PARAMS)
        return 1;
    else if (uj & USE_PARAMS)
        return 0;
    /* Put other objects before that */
    else if (ui & USE_OTHER_OBJECTS)
        return 1;
    else if (uj & USE_OTHER_OBJECTS)
        return 0;
    /* Put shared objects before that... */
    else if (ui & USE_SHARED)
        return 1;
    else if (uj & USE_SHARED)
        return 0;
    /* And otherwise, order by the page number on which
     * they are used. */
    return (ui>>USE_PAGE_SHIFT) >= (uj>>USE_PAGE_SHIFT);
}

static void
heap_sort(int *list, int n, const int *val, int (*ge)(int, int))
{
    int i, j;

    /* Step 1: Make a heap */
    /* Invariant: Valid heap in [0..i), unsorted elements in [i..n) */
    for (i = 1; i < n; i++)
    {
        /* Now bubble backwards to maintain heap invariant */
        j = i;
        while (j != 0)
        {
            int tmp;
            int k = (j-1)>>1;
            if (ge(val[list[k]], val[list[j]]))
                break;
            tmp = list[k];
            list[k] = list[j];
            list[j] = tmp;
            j = k;
        }
    }

    /* Step 2: Heap sort */
    /* Invariant: valid heap in [0..i), sorted list in [i..n) */
    /* Initially: i = n */
    for (i = n-1; i > 0; i--)
    {
        /* Swap the maximum (0th) element from the page_objects into its place
         * in the sorted list (position i). */
        int tmp = list[0];
        list[0] = list[i];
        list[i] = tmp;
        /* Now, the page_objects is invalid because the 0th element is out
         * of place. Bubble it until the page_objects is valid. */
        j = 0;
        while (1)
        {
            /* Children are k and k+1 */
            int k = (j+1)*2-1;
            /* If both children out of the page_objects, we're done */
            if (k > i-1)
                break;
            /* If both are in the page_objects, pick the larger one */
            if (k < i-1 && ge(val[list[k+1]], val[list[k]]))
                k++;
            /* If j is bigger than k (i.e. both of its children),
             * we're done */
            if (ge(val[list[j]], val[list[k]]))
                break;
            tmp = list[k];
            list[k] = list[j];
            list[j] = tmp;
            j = k;
        }
    }
}

static void
page_objects_dedupe(fz_context *ctx, page_objects *po)
{
    int i, j;
    int n = po->len-1;

    for (i = 0; i < n; i++)
    {
        if (po->object[i] == po->object[i+1])
            break;
    }
    j = i; /* j points to the last valid one */
    i++; /* i points to the first one we haven't looked at */
    for (; i < n; i++)
    {
        if (po->object[j] != po->object[i])
            po->object[++j] = po->object[i];
    }
    po->len = j+1;
}

static void
page_objects_list_sort_and_dedupe(fz_context *ctx, page_objects_list *pol)
{
    int i;
    int n = pol->len;

    for (i = 0; i < n; i++)
    {
        page_objects_sort(ctx, pol->page[i]);
        page_objects_dedupe(ctx, pol->page[i]);
    }
}

/*
 * Garbage collect objects not reachable from the trailer.
 */

/* Mark a reference. If it's been marked already, return NULL (as no further
 * processing is required). If it's not, return the resolved object so
 * that we can continue our recursive marking. If it's a duff reference
 * return the fact so that we can remove the reference at source.
 */
static pdf_obj *markref(fz_context *ctx, pdf_document *doc, pdf_write_state *opts, pdf_obj *obj, int *duff)
{
    int num = pdf_to_num(ctx, obj);

    if (num <= 0 || num >= pdf_xref_len(ctx, doc))
    {
        *duff = 1;
        return NULL;
    }
    *duff = 0;
    if (opts->use_list[num])
        return NULL;

    opts->use_list[num] = 1;

    /* Bake in /Length in stream objects */
    fz_try(ctx)
    {
        if (pdf_obj_num_is_stream(ctx, doc, num))
        {
            pdf_obj *len = pdf_dict_get(ctx, obj, PDF_NAME(Length));
            if (pdf_is_indirect(ctx, len))
            {
                opts->use_list[pdf_to_num(ctx, len)] = 0;
                len = pdf_resolve_indirect(ctx, len);
                pdf_dict_put(ctx, obj, PDF_NAME(Length), len);
            }
        }
    }
    fz_catch(ctx)
    {
        fz_rethrow_if(ctx, FZ_ERROR_TRYLATER);
        /* Leave broken */
    }

    obj = pdf_resolve_indirect(ctx, obj);
    if (obj == NULL || pdf_is_null(ctx, obj))
    {
        *duff = 1;
        opts->use_list[num] = 0;
    }

    return obj;
}

#ifdef DEBUG_MARK_AND_SWEEP
static int depth = 0;

static
void indent()
{
    while (depth > 0)
    {
        int d  = depth;
        if (d > 16)
            d = 16;
        printf("%s", &"                "[16-d]);
        depth -= d;
    }
}
#define DEBUGGING_MARKING(A) do { A; } while (0)
#else
#define DEBUGGING_MARKING(A) do { } while (0)
#endif

/* Recursively mark an object. If any references found are duff, then
 * replace them with nulls. */
static int markobj(fz_context *ctx, pdf_document *doc, pdf_write_state *opts, pdf_obj *obj)
{
    int i;

    DEBUGGING_MARKING(depth++);

    while (pdf_is_indirect(ctx, obj))
    {
        int duff;
        DEBUGGING_MARKING(indent(); printf("Marking object %d\n", pdf_to_num(ctx, obj)));
        obj = markref(ctx, doc, opts, obj, &duff);
        if (duff)
        {
            DEBUGGING_MARKING(depth--);
            return 1;
        }
    }

    if (pdf_is_dict(ctx, obj))
    {
        int n = pdf_dict_len(ctx, obj);
        for (i = 0; i < n; i++)
        {
            DEBUGGING_MARKING(indent(); printf("DICT[%d/%d] = %s\n", i, n, pdf_to_name(ctx, pdf_dict_get_key(ctx, obj, i))));
            if (markobj(ctx, doc, opts, pdf_dict_get_val(ctx, obj, i)))
                pdf_dict_put_val_null(ctx, obj, i);
        }
    }

    else if (pdf_is_array(ctx, obj))
    {
        int n = pdf_array_len(ctx, obj);
        for (i = 0; i < n; i++)
        {
            DEBUGGING_MARKING(indent(); printf("ARRAY[%d/%d]\n", i, n));
            if (markobj(ctx, doc, opts, pdf_array_get(ctx, obj, i)))
                pdf_array_put(ctx, obj, i, PDF_NULL);
        }
    }

    DEBUGGING_MARKING(depth--);

    return 0;
}

static void
expand_lists(fz_context *ctx, pdf_write_state *opts, int num)
{
    int i;

    /* objects are numbered 0..num and maybe two additional objects for linearization */
    num += 3;
    opts->use_list = fz_resize_array(ctx, opts->use_list, num, sizeof(*opts->use_list));
    opts->ofs_list = fz_resize_array(ctx, opts->ofs_list, num, sizeof(*opts->ofs_list));
    opts->gen_list = fz_resize_array(ctx, opts->gen_list, num, sizeof(*opts->gen_list));
    opts->renumber_map = fz_resize_array(ctx, opts->renumber_map, num, sizeof(*opts->renumber_map));
    opts->rev_renumber_map = fz_resize_array(ctx, opts->rev_renumber_map, num, sizeof(*opts->rev_renumber_map));

    for (i = opts->list_len; i < num; i++)
    {
        opts->use_list[i] = 0;
        opts->ofs_list[i] = 0;
        opts->gen_list[i] = 0;
        opts->renumber_map[i] = i;
        opts->rev_renumber_map[i] = i;
    }
    opts->list_len = num;
}

/*
 * Scan for and remove duplicate objects (slow)
 */

static void removeduplicateobjs(fz_context *ctx, pdf_document *doc, pdf_write_state *opts)
{
    int num, other, max_num;
    int xref_len = pdf_xref_len(ctx, doc);

    for (num = 1; num < xref_len; num++)
    {
        /* Only compare an object to objects preceding it */
        for (other = 1; other < num; other++)
        {
            pdf_obj *a, *b;
            int newnum, streama = 0, streamb = 0, differ = 0;

            if (num == other || !opts->use_list[num] || !opts->use_list[other])
                continue;

            /* TODO: resolve indirect references to see if we can omit them */

            /*
             * Comparing stream objects data contents would take too long.
             *
             * pdf_obj_num_is_stream calls pdf_cache_object and ensures
             * that the xref table has the objects loaded.
             */
            fz_try(ctx)
            {
                streama = pdf_obj_num_is_stream(ctx, doc, num);
                streamb = pdf_obj_num_is_stream(ctx, doc, other);
                differ = streama || streamb;
                if (streama && streamb && opts->do_garbage >= 4)
                    differ = 0;
            }
            fz_catch(ctx)
            {
                /* Assume different */
                differ = 1;
            }
            if (differ)
                continue;

            a = pdf_get_xref_entry(ctx, doc, num)->obj;
            b = pdf_get_xref_entry(ctx, doc, other)->obj;

            if (pdf_objcmp(ctx, a, b))
                continue;

            if (streama && streamb)
            {
                /* Check to see if streams match too. */
                fz_buffer *sa = NULL;
                fz_buffer *sb = NULL;

                fz_var(sa);
                fz_var(sb);

                differ = 1;
                fz_try(ctx)
                {
                    unsigned char *dataa, *datab;
                    size_t lena, lenb;
                    sa = pdf_load_raw_stream_number(ctx, doc, num);
                    sb = pdf_load_raw_stream_number(ctx, doc, other);
                    lena = fz_buffer_storage(ctx, sa, &dataa);
                    lenb = fz_buffer_storage(ctx, sb, &datab);
                    if (lena == lenb && memcmp(dataa, datab, lena) == 0)
                        differ = 0;
                }
                fz_always(ctx)
                {
                    fz_drop_buffer(ctx, sa);
                    fz_drop_buffer(ctx, sb);
                }
                fz_catch(ctx)
                {
                    fz_rethrow(ctx);
                }
                if (differ)
                    continue;
            }

            /* Keep the lowest numbered object */
            newnum = fz_mini(num, other);
            max_num = fz_maxi(num, other);
            if (max_num >= opts->list_len)
                expand_lists(ctx, opts, max_num);
            opts->renumber_map[num] = newnum;
            opts->renumber_map[other] = newnum;
            opts->rev_renumber_map[newnum] = num; /* Either will do */
            opts->use_list[fz_maxi(num, other)] = 0;

            /* One duplicate was found, do not look for another */
            break;
        }
    }
}

/*
 * Renumber objects sequentially so the xref is more compact
 *
 * This code assumes that any opts->renumber_map[n] <= n for all n.
 */

static void compactxref(fz_context *ctx, pdf_document *doc, pdf_write_state *opts)
{
    int num, newnum;
    int xref_len = pdf_xref_len(ctx, doc);

    /*
     * Update renumber_map in-place, clustering all used
     * objects together at low object ids. Objects that
     * already should be renumbered will have their new
     * object ids be updated to reflect the compaction.
     */

    if (xref_len > opts->list_len)
        expand_lists(ctx, opts, xref_len-1);

    newnum = 1;
    for (num = 1; num < xref_len; num++)
    {
        /* If it's not used, map it to zero */
        if (!opts->use_list[opts->renumber_map[num]])
        {
            opts->renumber_map[num] = 0;
        }
        /* If it's not moved, compact it. */
        else if (opts->renumber_map[num] == num)
        {
            opts->rev_renumber_map[newnum] = opts->rev_renumber_map[num];
            opts->renumber_map[num] = newnum++;
        }
        /* Otherwise it's used, and moved. We know that it must have
         * moved down, so the place it's moved to will be in the right
         * place already. */
        else
        {
            opts->renumber_map[num] = opts->renumber_map[opts->renumber_map[num]];
        }
    }
}

/*
 * Update indirect objects according to renumbering established when
 * removing duplicate objects and compacting the xref.
 */

static void renumberobj(fz_context *ctx, pdf_document *doc, pdf_write_state *opts, pdf_obj *obj)
{
    int i;
    int xref_len = pdf_xref_len(ctx, doc);

    if (pdf_is_dict(ctx, obj))
    {
        int n = pdf_dict_len(ctx, obj);
        for (i = 0; i < n; i++)
        {
            pdf_obj *key = pdf_dict_get_key(ctx, obj, i);
            pdf_obj *val = pdf_dict_get_val(ctx, obj, i);
            if (pdf_is_indirect(ctx, val))
            {
                int o = pdf_to_num(ctx, val);
                if (o >= xref_len || o <= 0 || opts->renumber_map[o] == 0)
                    val = PDF_NULL;
                else
                    val = pdf_new_indirect(ctx, doc, opts->renumber_map[o], 0);
                pdf_dict_put_drop(ctx, obj, key, val);
            }
            else
            {
                renumberobj(ctx, doc, opts, val);
            }
        }
    }

    else if (pdf_is_array(ctx, obj))
    {
        int n = pdf_array_len(ctx, obj);
        for (i = 0; i < n; i++)
        {
            pdf_obj *val = pdf_array_get(ctx, obj, i);
            if (pdf_is_indirect(ctx, val))
            {
                int o = pdf_to_num(ctx, val);
                if (o >= xref_len || o <= 0 || opts->renumber_map[o] == 0)
                    val = PDF_NULL;
                else
                    val = pdf_new_indirect(ctx, doc, opts->renumber_map[o], 0);
                pdf_array_put_drop(ctx, obj, i, val);
            }
            else
            {
                renumberobj(ctx, doc, opts, val);
            }
        }
    }
}

static void renumberobjs(fz_context *ctx, pdf_document *doc, pdf_write_state *opts)
{
    pdf_xref_entry *newxref = NULL;
    int newlen;
    int num;
    int *new_use_list;
    int xref_len = pdf_xref_len(ctx, doc);

    new_use_list = fz_calloc(ctx, pdf_xref_len(ctx, doc)+3, sizeof(int));

    fz_var(newxref);
    fz_try(ctx)
    {
        /* Apply renumber map to indirect references in all objects in xref */
        renumberobj(ctx, doc, opts, pdf_trailer(ctx, doc));
        for (num = 0; num < xref_len; num++)
        {
            pdf_obj *obj;
            int to = opts->renumber_map[num];

            /* If object is going to be dropped, don't bother renumbering */
            if (to == 0)
                continue;

            obj = pdf_get_xref_entry(ctx, doc, num)->obj;

            if (pdf_is_indirect(ctx, obj))
            {
                obj = pdf_new_indirect(ctx, doc, to, 0);
                fz_try(ctx)
                    pdf_update_object(ctx, doc, num, obj);
                fz_always(ctx)
                    pdf_drop_obj(ctx, obj);
                fz_catch(ctx)
                    fz_rethrow(ctx);
            }
            else
            {
                renumberobj(ctx, doc, opts, obj);
            }
        }

        /* Create new table for the reordered, compacted xref */
        newxref = fz_malloc_array(ctx, xref_len + 3, sizeof(pdf_xref_entry));
        newxref[0] = *pdf_get_xref_entry(ctx, doc, 0);

        /* Move used objects into the new compacted xref */
        newlen = 0;
        for (num = 1; num < xref_len; num++)
        {
            if (opts->use_list[num])
            {
                pdf_xref_entry *e;
                if (newlen < opts->renumber_map[num])
                    newlen = opts->renumber_map[num];
                e = pdf_get_xref_entry(ctx, doc, num);
                newxref[opts->renumber_map[num]] = *e;
                if (e->obj)
                {
                    pdf_set_obj_parent(ctx, e->obj, opts->renumber_map[num]);
                    e->obj = NULL;
                }
                new_use_list[opts->renumber_map[num]] = opts->use_list[num];
            }
            else
            {
                pdf_xref_entry *e = pdf_get_xref_entry(ctx, doc, num);
                pdf_drop_obj(ctx, e->obj);
                e->obj = NULL;
                fz_drop_buffer(ctx, e->stm_buf);
                e->stm_buf = NULL;
            }
        }

        pdf_replace_xref(ctx, doc, newxref, newlen + 1);
        newxref = NULL;
    }
    fz_catch(ctx)
    {
        fz_free(ctx, newxref);
        fz_free(ctx, new_use_list);
        fz_rethrow(ctx);
    }
    fz_free(ctx, opts->use_list);
    opts->use_list = new_use_list;

    for (num = 1; num < xref_len; num++)
    {
        opts->renumber_map[num] = num;
    }
}

static void page_objects_list_renumber(pdf_write_state *opts)
{
    int i, j;

    for (i = 0; i < opts->page_object_lists->len; i++)
    {
        page_objects *po = opts->page_object_lists->page[i];
        for (j = 0; j < po->len; j++)
        {
            po->object[j] = opts->renumber_map[po->object[j]];
        }
        po->page_object_number = opts->renumber_map[po->page_object_number];
    }
}

static void
mark_all(fz_context *ctx, pdf_document *doc, pdf_write_state *opts, pdf_obj *val, int flag, int page)
{
    if (pdf_mark_obj(ctx, val))
        return;

    fz_try(ctx)
    {
        if (pdf_is_indirect(ctx, val))
        {
            int num = pdf_to_num(ctx, val);
            if (opts->use_list[num] & USE_PAGE_MASK)
                /* Already used */
                opts->use_list[num] |= USE_SHARED;
            else
                opts->use_list[num] |= flag;
            if (page >= 0)
                page_objects_list_insert(ctx, opts, page, num);
        }

        if (pdf_is_dict(ctx, val))
        {
            int i, n = pdf_dict_len(ctx, val);

            for (i = 0; i < n; i++)
            {
                mark_all(ctx, doc, opts, pdf_dict_get_val(ctx, val, i), flag, page);
            }
        }
        else if (pdf_is_array(ctx, val))
        {
            int i, n = pdf_array_len(ctx, val);

            for (i = 0; i < n; i++)
            {
                mark_all(ctx, doc, opts, pdf_array_get(ctx, val, i), flag, page);
            }
        }
    }
    fz_always(ctx)
    {
        pdf_unmark_obj(ctx, val);
    }
    fz_catch(ctx)
    {
        fz_rethrow(ctx);
    }
}

static int
mark_pages(fz_context *ctx, pdf_document *doc, pdf_write_state *opts, pdf_obj *val, int pagenum)
{
    if (pdf_mark_obj(ctx, val))
        return pagenum;

    fz_try(ctx)
    {
        if (pdf_is_dict(ctx, val))
        {
            if (pdf_name_eq(ctx, PDF_NAME(Page), pdf_dict_get(ctx, val, PDF_NAME(Type))))
            {
                int num = pdf_to_num(ctx, val);
                pdf_unmark_obj(ctx, val);
                mark_all(ctx, doc, opts, val, pagenum == 0 ? USE_PAGE1 : (pagenum<<USE_PAGE_SHIFT), pagenum);
                page_objects_list_set_page_object(ctx, opts, pagenum, num);
                pagenum++;
                opts->use_list[num] |= USE_PAGE_OBJECT;
            }
            else
            {
                int i, n = pdf_dict_len(ctx, val);

                for (i = 0; i < n; i++)
                {
                    pdf_obj *key = pdf_dict_get_key(ctx, val, i);
                    pdf_obj *obj = pdf_dict_get_val(ctx, val, i);

                    if (pdf_name_eq(ctx, PDF_NAME(Kids), key))
                        pagenum = mark_pages(ctx, doc, opts, obj, pagenum);
                    else
                        mark_all(ctx, doc, opts, obj, USE_CATALOGUE, -1);
                }

                if (pdf_is_indirect(ctx, val))
                {
                    int num = pdf_to_num(ctx, val);
                    opts->use_list[num] |= USE_CATALOGUE;
                }
            }
        }
        else if (pdf_is_array(ctx, val))
        {
            int i, n = pdf_array_len(ctx, val);

            for (i = 0; i < n; i++)
            {
                pagenum = mark_pages(ctx, doc, opts, pdf_array_get(ctx, val, i), pagenum);
            }
            if (pdf_is_indirect(ctx, val))
            {
                int num = pdf_to_num(ctx, val);
                opts->use_list[num] |= USE_CATALOGUE;
            }
        }
    }
    fz_always(ctx)
    {
        pdf_unmark_obj(ctx, val);
    }
    fz_catch(ctx)
    {
        fz_rethrow(ctx);
    }
    return pagenum;
}

static void
mark_root(fz_context *ctx, pdf_document *doc, pdf_write_state *opts, pdf_obj *dict)
{
    int i, n = pdf_dict_len(ctx, dict);

    if (pdf_mark_obj(ctx, dict))
        return;

    fz_try(ctx)
    {
        if (pdf_is_indirect(ctx, dict))
        {
            int num = pdf_to_num(ctx, dict);
            opts->use_list[num] |= USE_CATALOGUE;
        }

        for (i = 0; i < n; i++)
        {
            pdf_obj *key = pdf_dict_get_key(ctx, dict, i);
            pdf_obj *val = pdf_dict_get_val(ctx, dict, i);

            if (pdf_name_eq(ctx, PDF_NAME(Pages), key))
                opts->page_count = mark_pages(ctx, doc, opts, val, 0);
            else if (pdf_name_eq(ctx, PDF_NAME(Names), key))
                mark_all(ctx, doc, opts, val, USE_OTHER_OBJECTS, -1);
            else if (pdf_name_eq(ctx, PDF_NAME(Dests), key))
                mark_all(ctx, doc, opts, val, USE_OTHER_OBJECTS, -1);
            else if (pdf_name_eq(ctx, PDF_NAME(Outlines), key))
            {
                int section;
                /* Look at PageMode to decide whether to
                 * USE_OTHER_OBJECTS or USE_PAGE1 here. */
                if (pdf_name_eq(ctx, pdf_dict_get(ctx, dict, PDF_NAME(PageMode)), PDF_NAME(UseOutlines)))
                    section = USE_PAGE1;
                else
                    section = USE_OTHER_OBJECTS;
                mark_all(ctx, doc, opts, val, section, -1);
            }
            else
                mark_all(ctx, doc, opts, val, USE_CATALOGUE, -1);
        }
    }
    fz_always(ctx)
    {
        pdf_unmark_obj(ctx, dict);
    }
    fz_catch(ctx)
    {
        fz_rethrow(ctx);
    }
}

static void
mark_trailer(fz_context *ctx, pdf_document *doc, pdf_write_state *opts, pdf_obj *dict)
{
    int i, n = pdf_dict_len(ctx, dict);

    if (pdf_mark_obj(ctx, dict))
        return;

    fz_try(ctx)
    {
        for (i = 0; i < n; i++)
        {
            pdf_obj *key = pdf_dict_get_key(ctx, dict, i);
            pdf_obj *val = pdf_dict_get_val(ctx, dict, i);

            if (pdf_name_eq(ctx, PDF_NAME(Root), key))
                mark_root(ctx, doc, opts, val);
            else
                mark_all(ctx, doc, opts, val, USE_CATALOGUE, -1);
        }
    }
    fz_always(ctx)
    {
        pdf_unmark_obj(ctx, dict);
    }
    fz_catch(ctx)
    {
        fz_rethrow(ctx);
    }
}

static void
add_linearization_objs(fz_context *ctx, pdf_document *doc, pdf_write_state *opts)
{
    pdf_obj *params_obj = NULL;
    pdf_obj *params_ref = NULL;
    pdf_obj *hint_obj = NULL;
    pdf_obj *hint_ref = NULL;
    pdf_obj *o;
    int params_num, hint_num;

    fz_var(params_obj);
    fz_var(params_ref);
    fz_var(hint_obj);
    fz_var(hint_ref);

    fz_try(ctx)
    {
        /* Linearization params */
        params_obj = pdf_new_dict(ctx, doc, 10);
        params_ref = pdf_add_object(ctx, doc, params_obj);
        params_num = pdf_to_num(ctx, params_ref);

        opts->use_list[params_num] = USE_PARAMS;
        opts->renumber_map[params_num] = params_num;
        opts->rev_renumber_map[params_num] = params_num;
        opts->gen_list[params_num] = 0;
        pdf_dict_put_real(ctx, params_obj, PDF_NAME(Linearized), 1.0f);
        opts->linear_l = pdf_new_int(ctx, INT_MIN);
        pdf_dict_put(ctx, params_obj, PDF_NAME(L), opts->linear_l);
        opts->linear_h0 = pdf_new_int(ctx, INT_MIN);
        o = pdf_new_array(ctx, doc, 2);
        pdf_dict_put_drop(ctx, params_obj, PDF_NAME(H), o);
        pdf_array_push(ctx, o, opts->linear_h0);
        opts->linear_h1 = pdf_new_int(ctx, INT_MIN);
        pdf_array_push(ctx, o, opts->linear_h1);
        opts->linear_o = pdf_new_int(ctx, INT_MIN);
        pdf_dict_put(ctx, params_obj, PDF_NAME(O), opts->linear_o);
        opts->linear_e = pdf_new_int(ctx, INT_MIN);
        pdf_dict_put(ctx, params_obj, PDF_NAME(E), opts->linear_e);
        opts->linear_n = pdf_new_int(ctx, INT_MIN);
        pdf_dict_put(ctx, params_obj, PDF_NAME(N), opts->linear_n);
        opts->linear_t = pdf_new_int(ctx, INT_MIN);
        pdf_dict_put(ctx, params_obj, PDF_NAME(T), opts->linear_t);

        /* Primary hint stream */
        hint_obj = pdf_new_dict(ctx, doc, 10);
        hint_ref = pdf_add_object(ctx, doc, hint_obj);
        hint_num = pdf_to_num(ctx, hint_ref);

        opts->use_list[hint_num] = USE_HINTS;
        opts->renumber_map[hint_num] = hint_num;
        opts->rev_renumber_map[hint_num] = hint_num;
        opts->gen_list[hint_num] = 0;
        pdf_dict_put_int(ctx, hint_obj, PDF_NAME(P), 0);
        opts->hints_s = pdf_new_int(ctx, INT_MIN);
        pdf_dict_put(ctx, hint_obj, PDF_NAME(S), opts->hints_s);
        /* FIXME: Do we have thumbnails? Do a T entry */
        /* FIXME: Do we have outlines? Do an O entry */
        /* FIXME: Do we have article threads? Do an A entry */
        /* FIXME: Do we have named destinations? Do a E entry */
        /* FIXME: Do we have interactive forms? Do a V entry */
        /* FIXME: Do we have document information? Do an I entry */
        /* FIXME: Do we have logical structure hierarchy? Do a C entry */
        /* FIXME: Do L, Page Label hint table */
        pdf_dict_put(ctx, hint_obj, PDF_NAME(Filter), PDF_NAME(FlateDecode));
        opts->hints_length = pdf_new_int(ctx, INT_MIN);
        pdf_dict_put(ctx, hint_obj, PDF_NAME(Length), opts->hints_length);
        pdf_get_xref_entry(ctx, doc, hint_num)->stm_ofs = -1;
    }
    fz_always(ctx)
    {
        pdf_drop_obj(ctx, params_obj);
        pdf_drop_obj(ctx, params_ref);
        pdf_drop_obj(ctx, hint_ref);
        pdf_drop_obj(ctx, hint_obj);
    }
    fz_catch(ctx)
    {
        fz_rethrow(ctx);
    }
}

static void
lpr_inherit_res_contents(fz_context *ctx, pdf_obj *res, pdf_obj *dict, pdf_obj *text)
{
    pdf_obj *o, *r;
    int i, n;

    /* If the parent node doesn't have an entry of this type, give up. */
    o = pdf_dict_get(ctx, dict, text);
    if (!o)
        return;

    /* If the resources dict we are building doesn't have an entry of this
     * type yet, then just copy it (ensuring it's not a reference) */
    r = pdf_dict_get(ctx, res, text);
    if (r == NULL)
    {
        o = pdf_resolve_indirect(ctx, o);
        if (pdf_is_dict(ctx, o))
            o = pdf_copy_dict(ctx, o);
        else if (pdf_is_array(ctx, o))
            o = pdf_copy_array(ctx, o);
        else
            o = NULL;
        if (o)
            pdf_dict_put_drop(ctx, res, text, o);
        return;
    }

    /* Otherwise we need to merge o into r */
    if (pdf_is_dict(ctx, o))
    {
        n = pdf_dict_len(ctx, o);
        for (i = 0; i < n; i++)
        {
            pdf_obj *key = pdf_dict_get_key(ctx, o, i);
            pdf_obj *val = pdf_dict_get_val(ctx, o, i);

            if (pdf_dict_get(ctx, res, key))
                continue;
            pdf_dict_put(ctx, res, key, val);
        }
    }
}

static void
lpr_inherit_res(fz_context *ctx, pdf_obj *node, int depth, pdf_obj *dict)
{
    while (1)
    {
        pdf_obj *o;

        node = pdf_dict_get(ctx, node, PDF_NAME(Parent));
        depth--;
        if (!node || depth < 0)
            break;

        o = pdf_dict_get(ctx, node, PDF_NAME(Resources));
        if (o)
        {
            lpr_inherit_res_contents(ctx, dict, o, PDF_NAME(ExtGState));
            lpr_inherit_res_contents(ctx, dict, o, PDF_NAME(ColorSpace));
            lpr_inherit_res_contents(ctx, dict, o, PDF_NAME(Pattern));
            lpr_inherit_res_contents(ctx, dict, o, PDF_NAME(Shading));
            lpr_inherit_res_contents(ctx, dict, o, PDF_NAME(XObject));
            lpr_inherit_res_contents(ctx, dict, o, PDF_NAME(Font));
            lpr_inherit_res_contents(ctx, dict, o, PDF_NAME(ProcSet));
            lpr_inherit_res_contents(ctx, dict, o, PDF_NAME(Properties));
        }
    }
}

static pdf_obj *
lpr_inherit(fz_context *ctx, pdf_obj *node, char *text, int depth)
{
    do
    {
        pdf_obj *o = pdf_dict_gets(ctx, node, text);

        if (o)
            return pdf_resolve_indirect(ctx, o);
        node = pdf_dict_get(ctx, node, PDF_NAME(Parent));
        depth--;
    }
    while (depth >= 0 && node);

    return NULL;
}

static int
lpr(fz_context *ctx, pdf_document *doc, pdf_obj *node, int depth, int page)
{
    pdf_obj *kids;
    pdf_obj *o = NULL;
    int i, n;

    if (pdf_mark_obj(ctx, node))
        return page;

    fz_var(o);

    fz_try(ctx)
    {
        if (pdf_name_eq(ctx, PDF_NAME(Page), pdf_dict_get(ctx, node, PDF_NAME(Type))))
        {
            pdf_obj *r; /* r is deliberately not cleaned up */

            /* Copy resources down to the child */
            o = pdf_keep_obj(ctx, pdf_dict_get(ctx, node, PDF_NAME(Resources)));
            if (!o)
            {
                o = pdf_keep_obj(ctx, pdf_new_dict(ctx, doc, 2));
                pdf_dict_put(ctx, node, PDF_NAME(Resources), o);
            }
            lpr_inherit_res(ctx, node, depth, o);
            r = lpr_inherit(ctx, node, "MediaBox", depth);
            if (r)
                pdf_dict_put(ctx, node, PDF_NAME(MediaBox), r);
            r = lpr_inherit(ctx, node, "CropBox", depth);
            if (r)
                pdf_dict_put(ctx, node, PDF_NAME(CropBox), r);
            r = lpr_inherit(ctx, node, "BleedBox", depth);
            if (r)
                pdf_dict_put(ctx, node, PDF_NAME(BleedBox), r);
            r = lpr_inherit(ctx, node, "TrimBox", depth);
            if (r)
                pdf_dict_put(ctx, node, PDF_NAME(TrimBox), r);
            r = lpr_inherit(ctx, node, "ArtBox", depth);
            if (r)
                pdf_dict_put(ctx, node, PDF_NAME(ArtBox), r);
            r = lpr_inherit(ctx, node, "Rotate", depth);
            if (r)
                pdf_dict_put(ctx, node, PDF_NAME(Rotate), r);
            page++;
        }
        else
        {
            kids = pdf_dict_get(ctx, node, PDF_NAME(Kids));
            n = pdf_array_len(ctx, kids);
            for(i = 0; i < n; i++)
            {
                page = lpr(ctx, doc, pdf_array_get(ctx, kids, i), depth+1, page);
            }
            pdf_dict_del(ctx, node, PDF_NAME(Resources));
            pdf_dict_del(ctx, node, PDF_NAME(MediaBox));
            pdf_dict_del(ctx, node, PDF_NAME(CropBox));
            pdf_dict_del(ctx, node, PDF_NAME(BleedBox));
            pdf_dict_del(ctx, node, PDF_NAME(TrimBox));
            pdf_dict_del(ctx, node, PDF_NAME(ArtBox));
            pdf_dict_del(ctx, node, PDF_NAME(Rotate));
        }
    }
    fz_always(ctx)
    {
        pdf_drop_obj(ctx, o);
    }
    fz_catch(ctx)
    {
        fz_rethrow(ctx);
    }

    pdf_unmark_obj(ctx, node);

    return page;
}

static void
linearize(fz_context *ctx, pdf_document *doc, pdf_write_state *opts)
{
    int i;
    int n = pdf_xref_len(ctx, doc) + 2;
    int *reorder;
    int *rev_renumber_map;

    opts->page_object_lists = page_objects_list_create(ctx);

    /* Ensure that every page has local references of its resources */
    /* FIXME: We could 'thin' the resources according to what is actually
     * required for each page, but this would require us to run the page
     * content streams. */
    pdf_localise_page_resources(ctx, doc);

    /* Walk the objects for each page, marking which ones are used, where */
    memset(opts->use_list, 0, n * sizeof(int));
    mark_trailer(ctx, doc, opts, pdf_trailer(ctx, doc));

    /* Add new objects required for linearization */
    add_linearization_objs(ctx, doc, opts);

    /* Allocate/init the structures used for renumbering the objects */
    reorder = fz_calloc(ctx, n, sizeof(int));
    rev_renumber_map = fz_calloc(ctx, n, sizeof(int));
    for (i = 0; i < n; i++)
    {
        reorder[i] = i;
    }

    /* Heap sort the reordering */
    heap_sort(reorder+1, n-1, opts->use_list, &order_ge);

    /* Find the split point */
    for (i = 1; (opts->use_list[reorder[i]] & USE_PARAMS) == 0; i++) {}
    opts->start = i;

    /* Roll the reordering into the renumber_map */
    for (i = 0; i < n; i++)
    {
        opts->renumber_map[reorder[i]] = i;
        rev_renumber_map[i] = opts->rev_renumber_map[reorder[i]];
    }
    fz_free(ctx, opts->rev_renumber_map);
    opts->rev_renumber_map = rev_renumber_map;
    fz_free(ctx, reorder);

    /* Apply the renumber_map */
    page_objects_list_renumber(opts);
    renumberobjs(ctx, doc, opts);

    page_objects_list_sort_and_dedupe(ctx, opts->page_object_lists);
}

static void
update_linearization_params(fz_context *ctx, pdf_document *doc, pdf_write_state *opts)
{
    int64_t offset;
    pdf_set_int(ctx, opts->linear_l, opts->file_len);
    /* Primary hint stream offset (of object, not stream!) */
    pdf_set_int(ctx, opts->linear_h0, opts->ofs_list[pdf_xref_len(ctx, doc)-1]);
    /* Primary hint stream length (of object, not stream!) */
    offset = (opts->start == 1 ? opts->main_xref_offset : opts->ofs_list[1] + opts->hintstream_len);
    pdf_set_int(ctx, opts->linear_h1, offset - opts->ofs_list[pdf_xref_len(ctx, doc)-1]);
    /* Object number of first pages page object (the first object of page 0) */
    pdf_set_int(ctx, opts->linear_o, opts->page_object_lists->page[0]->object[0]);
    /* Offset of end of first page (first page is followed by primary
     * hint stream (object n-1) then remaining pages (object 1...). The
     * primary hint stream counts as part of the first pages data, I think.
     */
    offset = (opts->start == 1 ? opts->main_xref_offset : opts->ofs_list[1] + opts->hintstream_len);
    pdf_set_int(ctx, opts->linear_e, offset);
    /* Number of pages in document */
    pdf_set_int(ctx, opts->linear_n, opts->page_count);
    /* Offset of first entry in main xref table */
    pdf_set_int(ctx, opts->linear_t, opts->first_xref_entry_offset + opts->hintstream_len);
    /* Offset of shared objects hint table in the primary hint stream */
    pdf_set_int(ctx, opts->hints_s, opts->hints_shared_offset);
    /* Primary hint stream length */
    pdf_set_int(ctx, opts->hints_length, opts->hintstream_len);
}

/*
 * Make sure we have loaded objects from object streams.
 */

static void preloadobjstms(fz_context *ctx, pdf_document *doc)
{
    pdf_obj *obj;
    int num;

    /* xref_len may change due to repair, so check it every iteration */
    for (num = 0; num < pdf_xref_len(ctx, doc); num++)
    {
        if (pdf_get_xref_entry(ctx, doc, num)->type == 'o')
        {
            obj = pdf_load_object(ctx, doc, num);
            pdf_drop_obj(ctx, obj);
        }
    }
}

/*
 * Save streams and objects to the output
 */

static inline int isbinary(int c)
{
    if (c == '\n' || c == '\r' || c == '\t')
        return 0;
    return c < 32 || c > 127;
}

static int isbinarystream(fz_context *ctx, fz_buffer *buf)
{
    unsigned char *data;
    size_t len = fz_buffer_storage(ctx, buf, &data);
    size_t i;
    for (i = 0; i < len; i++)
        if (isbinary(data[i]))
            return 1;
    return 0;
}

static fz_buffer *hexbuf(fz_context *ctx, const unsigned char *p, size_t n)
{
    static const char hex[17] = "0123456789abcdef";
    int x = 0;
    size_t len = n * 2 + (n / 32) + 1;
    unsigned char *data = fz_malloc(ctx, len);
    fz_buffer *buf = fz_new_buffer_from_data(ctx, data, len);

    while (n--)
    {
        *data++ = hex[*p >> 4];
        *data++ = hex[*p & 15];
        if (++x == 32)
        {
            *data++ = '\n';
            x = 0;
        }
        p++;
    }

    *data++ = '>';

    return buf;
}

static void addhexfilter(fz_context *ctx, pdf_document *doc, pdf_obj *dict)
{
    pdf_obj *f, *dp, *newf, *newdp;

    newf = newdp = NULL;
    f = pdf_dict_get(ctx, dict, PDF_NAME(Filter));
    dp = pdf_dict_get(ctx, dict, PDF_NAME(DecodeParms));

    fz_var(newf);
    fz_var(newdp);

    fz_try(ctx)
    {
        if (pdf_is_name(ctx, f))
        {
            newf = pdf_new_array(ctx, doc, 2);
            pdf_array_push(ctx, newf, PDF_NAME(ASCIIHexDecode));
            pdf_array_push(ctx, newf, f);
            f = newf;
            if (pdf_is_dict(ctx, dp))
            {
                newdp = pdf_new_array(ctx, doc, 2);
                pdf_array_push(ctx, newdp, PDF_NULL);
                pdf_array_push(ctx, newdp, dp);
                dp = newdp;
            }
        }
        else if (pdf_is_array(ctx, f))
        {
            pdf_array_insert(ctx, f, PDF_NAME(ASCIIHexDecode), 0);
            if (pdf_is_array(ctx, dp))
                pdf_array_insert(ctx, dp, PDF_NULL, 0);
        }
        else
            f = PDF_NAME(ASCIIHexDecode);

        pdf_dict_put(ctx, dict, PDF_NAME(Filter), f);
        if (dp)
            pdf_dict_put(ctx, dict, PDF_NAME(DecodeParms), dp);
    }
    fz_always(ctx)
    {
        pdf_drop_obj(ctx, newf);
        pdf_drop_obj(ctx, newdp);
    }
    fz_catch(ctx)
        fz_rethrow(ctx);
}

static fz_buffer *deflatebuf(fz_context *ctx, const unsigned char *p, size_t n)
{
    fz_buffer *buf;
    uLongf csize;
    int t;
    uLong longN = (uLong)n;
    unsigned char *data;
    size_t cap;

    if (n != (size_t)longN)
        fz_throw(ctx, FZ_ERROR_GENERIC, "Buffer too large to deflate");

    cap = compressBound(longN);
    data = fz_malloc(ctx, cap);
    buf = fz_new_buffer_from_data(ctx, data, cap);
    csize = (uLongf)cap;
    t = compress(data, &csize, p, longN);
    if (t != Z_OK)
    {
        fz_drop_buffer(ctx, buf);
        fz_throw(ctx, FZ_ERROR_GENERIC, "cannot deflate buffer");
    }
    fz_resize_buffer(ctx, buf, csize);
    return buf;
}

static void write_data(fz_context *ctx, void *arg, const unsigned char *data, int len)
{
    fz_write_data(ctx, (fz_output *)arg, data, len);
}

static void copystream(fz_context *ctx, pdf_document *doc, pdf_write_state *opts, pdf_obj *obj_orig, int num, int gen, int do_deflate)
{
    fz_buffer *buf, *tmp;
    pdf_obj *obj;
    size_t len;
    unsigned char *data;

    buf = pdf_load_raw_stream_number(ctx, doc, num);

    obj = pdf_copy_dict(ctx, obj_orig);

    len = fz_buffer_storage(ctx, buf, &data);
    if (do_deflate && !pdf_dict_get(ctx, obj, PDF_NAME(Filter)))
    {
        size_t clen;
        unsigned char *cdata;
        tmp = deflatebuf(ctx, data, len);
        clen = fz_buffer_storage(ctx, tmp, &cdata);
        if (clen >= len)
        {
            /* Don't bother compressing, as we gain nothing. */
            fz_drop_buffer(ctx, tmp);
        }
        else
        {
            len = clen;
            data = cdata;
            pdf_dict_put(ctx, obj, PDF_NAME(Filter), PDF_NAME(FlateDecode));
            fz_drop_buffer(ctx, buf);
            buf = tmp;
        }
    }

    if (opts->do_ascii && isbinarystream(ctx, buf))
    {
        tmp = hexbuf(ctx, data, len);
        fz_drop_buffer(ctx, buf);
        buf = tmp;
        len = fz_buffer_storage(ctx, buf, &data);

        addhexfilter(ctx, doc, obj);
    }

    pdf_dict_put_int(ctx, obj, PDF_NAME(Length), pdf_encrypted_len(ctx, NULL, num, gen, (int)len));

    fz_write_printf(ctx, opts->out, "%d %d obj\n", num, gen);
    pdf_print_encrypted_obj(ctx, opts->out, obj, opts->do_tight, NULL, num, gen);
    fz_write_string(ctx, opts->out, "\nstream\n");
    pdf_encrypt_data(ctx, NULL, num, gen, write_data, opts->out, data, (int) len);
    fz_write_string(ctx, opts->out, "\nendstream\nendobj\n\n");

    fz_drop_buffer(ctx, buf);
    pdf_drop_obj(ctx, obj);
}

static void expandstream(fz_context *ctx, pdf_document *doc, pdf_write_state *opts, pdf_obj *obj_orig, int num, int gen, int do_deflate)
{
    fz_buffer *buf, *tmp;
    pdf_obj *obj;
    int truncated = 0;
    size_t len;
    unsigned char *data;

    buf = pdf_load_stream_truncated(ctx, doc, num, (opts->continue_on_error ? &truncated : NULL));
    if (truncated && opts->errors)
        (*opts->errors)++;

    obj = pdf_copy_dict(ctx, obj_orig);
    pdf_dict_del(ctx, obj, PDF_NAME(Filter));
    pdf_dict_del(ctx, obj, PDF_NAME(DecodeParms));

    len = fz_buffer_storage(ctx, buf, &data);
    if (do_deflate)
    {
        unsigned char *cdata;
        size_t clen;
        tmp = deflatebuf(ctx, data, len);
        clen = fz_buffer_storage(ctx, tmp, &cdata);
        if (clen >= len)
        {
            /* Don't bother compressing, as we gain nothing. */
            fz_drop_buffer(ctx, tmp);
        }
        else
        {
            len = clen;
            data = cdata;
            pdf_dict_put(ctx, obj, PDF_NAME(Filter), PDF_NAME(FlateDecode));
            fz_drop_buffer(ctx, buf);
            buf = tmp;
        }
    }

    if (opts->do_ascii && isbinarystream(ctx, buf))
    {
        tmp = hexbuf(ctx, data, len);
        fz_drop_buffer(ctx, buf);
        buf = tmp;
        len = fz_buffer_storage(ctx, buf, &data);

        addhexfilter(ctx, doc, obj);
    }

    pdf_dict_put_int(ctx, obj, PDF_NAME(Length), len);

    fz_write_printf(ctx, opts->out, "%d %d obj\n", num, gen);
    pdf_print_encrypted_obj(ctx, opts->out, obj, opts->do_tight, NULL, num, gen);
    fz_write_string(ctx, opts->out, "\nstream\n");
    fz_write_data(ctx, opts->out, data, len);
    fz_write_string(ctx, opts->out, "\nendstream\nendobj\n\n");

    fz_drop_buffer(ctx, buf);
    pdf_drop_obj(ctx, obj);
}

static int is_image_filter(const char *s)
{
    if (!strcmp(s, "CCITTFaxDecode") || !strcmp(s, "CCF") ||
        !strcmp(s, "DCTDecode") || !strcmp(s, "DCT") ||
        !strcmp(s, "RunLengthDecode") || !strcmp(s, "RL") ||
        !strcmp(s, "JBIG2Decode") ||
        !strcmp(s, "JPXDecode"))
        return 1;
    return 0;
}

static int filter_implies_image(fz_context *ctx, pdf_obj *o)
{
    if (!o)
        return 0;
    if (pdf_is_name(ctx, o))
        return is_image_filter(pdf_to_name(ctx, o));
    if (pdf_is_array(ctx, o))
    {
        int i, len;
        len = pdf_array_len(ctx, o);
        for (i = 0; i < len; i++)
            if (is_image_filter(pdf_to_name(ctx, pdf_array_get(ctx, o, i))))
                return 1;
    }
    return 0;
}

static int is_image_stream(fz_context *ctx, pdf_obj *obj)
{
    pdf_obj *o;
    if ((o = pdf_dict_get(ctx, obj, PDF_NAME(Type)), pdf_name_eq(ctx, o, PDF_NAME(XObject))))
        if ((o = pdf_dict_get(ctx, obj, PDF_NAME(Subtype)), pdf_name_eq(ctx, o, PDF_NAME(Image))))
            return 1;
    if (o = pdf_dict_get(ctx, obj, PDF_NAME(Filter)), filter_implies_image(ctx, o))
        return 1;
    if (pdf_dict_get(ctx, obj, PDF_NAME(Width)) != NULL && pdf_dict_get(ctx, obj, PDF_NAME(Height)) != NULL)
        return 1;
    return 0;
}

static int is_font_stream(fz_context *ctx, pdf_obj *obj)
{
    pdf_obj *o;
    if (o = pdf_dict_get(ctx, obj, PDF_NAME(Type)), pdf_name_eq(ctx, o, PDF_NAME(Font)))
        return 1;
    if (o = pdf_dict_get(ctx, obj, PDF_NAME(Type)), pdf_name_eq(ctx, o, PDF_NAME(FontDescriptor)))
        return 1;
    if (pdf_dict_get(ctx, obj, PDF_NAME(Length1)) != NULL)
        return 1;
    if (pdf_dict_get(ctx, obj, PDF_NAME(Length2)) != NULL)
        return 1;
    if (pdf_dict_get(ctx, obj, PDF_NAME(Length3)) != NULL)
        return 1;
    if (o = pdf_dict_get(ctx, obj, PDF_NAME(Subtype)), pdf_name_eq(ctx, o, PDF_NAME(Type1C)))
        return 1;
    if (o = pdf_dict_get(ctx, obj, PDF_NAME(Subtype)), pdf_name_eq(ctx, o, PDF_NAME(CIDFontType0C)))
        return 1;
    return 0;
}

static int is_xml_metadata(fz_context *ctx, pdf_obj *obj)
{
    if (pdf_name_eq(ctx, pdf_dict_get(ctx, obj, PDF_NAME(Type)), PDF_NAME(Metadata)))
        if (pdf_name_eq(ctx, pdf_dict_get(ctx, obj, PDF_NAME(Subtype)), PDF_NAME(XML)))
            return 1;
    return 0;
}

static void writeobject(fz_context *ctx, pdf_document *doc, pdf_write_state *opts, int num, int gen, int skip_xrefs, int unenc)
{
    if (unenc) return;
    pdf_xref_entry *entry;
    pdf_obj *obj;
    pdf_obj *type;

    fz_try(ctx)
    {
        obj = pdf_load_object(ctx, doc, num);
    }
    fz_catch(ctx)
    {
        fz_rethrow_if(ctx, FZ_ERROR_TRYLATER);
        if (opts->continue_on_error)
        {
            fz_write_printf(ctx, opts->out, "%d %d obj\nnull\nendobj\n", num, gen);
            if (opts->errors)
                (*opts->errors)++;
            fz_warn(ctx, "%s", fz_caught_message(ctx));
            return;
        }
        else
            fz_rethrow(ctx);
    }

    /* skip ObjStm and XRef objects */
    if (pdf_is_dict(ctx, obj))
    {
        type = pdf_dict_get(ctx, obj, PDF_NAME(Type));
        if (pdf_name_eq(ctx, type, PDF_NAME(ObjStm)))
        {
            opts->use_list[num] = 0;
            pdf_drop_obj(ctx, obj);
            return;
        }
        if (skip_xrefs && pdf_name_eq(ctx, type, PDF_NAME(XRef)))
        {
            opts->use_list[num] = 0;
            pdf_drop_obj(ctx, obj);
            return;
        }
    }

    entry = pdf_get_xref_entry(ctx, doc, num);
    if (!pdf_obj_num_is_stream(ctx, doc, num))
    {
        fz_write_printf(ctx, opts->out, "%d %d obj\n", num, gen);
        pdf_print_encrypted_obj(ctx, opts->out, obj, opts->do_tight, NULL, num, gen);
        fz_write_string(ctx, opts->out, "\nendobj\n\n");
    }
    else if (entry->stm_ofs < 0 && entry->stm_buf == NULL)
    {
        fz_write_printf(ctx, opts->out, "%d %d obj\n", num, gen);
        pdf_print_encrypted_obj(ctx, opts->out, obj, opts->do_tight, NULL, num, gen);
        fz_write_string(ctx, opts->out, "\nstream\nendstream\nendobj\n\n");
    }
    else
    {
        fz_try(ctx)
        {
            int do_deflate = opts->do_compress;
            int do_expand = opts->do_expand;
            if (opts->do_compress_images && is_image_stream(ctx, obj))
                do_deflate = 1, do_expand = 0;
            if (opts->do_compress_fonts && is_font_stream(ctx, obj))
                do_deflate = 1, do_expand = 0;
            if (is_xml_metadata(ctx, obj))
                do_deflate = 0, do_expand = 0;
            if (do_expand)
                expandstream(ctx, doc, opts, obj, num, gen, do_deflate);
            else
                copystream(ctx, doc, opts, obj, num, gen, do_deflate);
        }
        fz_catch(ctx)
        {
            fz_rethrow_if(ctx, FZ_ERROR_TRYLATER);
            if (opts->continue_on_error)
            {
                fz_write_printf(ctx, opts->out, "%d %d obj\nnull\nendobj\n", num, gen);
                if (opts->errors)
                    (*opts->errors)++;
                fz_warn(ctx, "%s", fz_caught_message(ctx));
            }
            else
            {
                pdf_drop_obj(ctx, obj);
                fz_rethrow(ctx);
            }
        }
    }

    pdf_drop_obj(ctx, obj);
}

static void writexrefsubsect(fz_context *ctx, pdf_write_state *opts, int from, int to)
{
    int num;

    fz_write_printf(ctx, opts->out, "%d %d\n", from, to - from);
    for (num = from; num < to; num++)
    {
        if (opts->use_list[num])
            fz_write_printf(ctx, opts->out, "%010lu %05d n \n", opts->ofs_list[num], opts->gen_list[num]);
        else
            fz_write_printf(ctx, opts->out, "%010lu %05d f \n", opts->ofs_list[num], opts->gen_list[num]);
    }
}

static void writexref(fz_context *ctx, pdf_document *doc, pdf_write_state *opts, int from, int to, int first, int64_t main_xref_offset, int64_t startxref)
{
    pdf_obj *trailer = NULL;
    pdf_obj *obj;
    pdf_obj *nobj = NULL;

    fz_write_string(ctx, opts->out, "xref\n");
    opts->first_xref_entry_offset = fz_tell_output(ctx, opts->out);

    if (opts->do_incremental)
    {
        int subfrom = from;
        int subto;

        while (subfrom < to)
        {
            while (subfrom < to && !pdf_xref_is_incremental(ctx, doc, subfrom))
                subfrom++;

            subto = subfrom;
            while (subto < to && pdf_xref_is_incremental(ctx, doc, subto))
                subto++;

            if (subfrom < subto)
                writexrefsubsect(ctx, opts, subfrom, subto);

            subfrom = subto;
        }
    }
    else
    {
        writexrefsubsect(ctx, opts, from, to);
    }

    fz_write_string(ctx, opts->out, "\n");

    fz_var(trailer);

    if (opts->do_incremental)
    {
        trailer = pdf_keep_obj(ctx, pdf_trailer(ctx, doc));
        pdf_dict_put_int(ctx, trailer, PDF_NAME(Size), pdf_xref_len(ctx, doc));
        pdf_dict_put_int(ctx, trailer, PDF_NAME(Prev), doc->startxref);
        doc->startxref = startxref;
    }
    else
    {
        trailer = pdf_new_dict(ctx, doc, 5);

        nobj = pdf_new_int(ctx, to);
        pdf_dict_put_drop(ctx, trailer, PDF_NAME(Size), nobj);

        if (first)
        {
            obj = pdf_dict_get(ctx, pdf_trailer(ctx, doc), PDF_NAME(Info));
            if (obj)
                pdf_dict_put(ctx, trailer, PDF_NAME(Info), obj);

            obj = pdf_dict_get(ctx, pdf_trailer(ctx, doc), PDF_NAME(Root));
            if (obj)
                pdf_dict_put(ctx, trailer, PDF_NAME(Root), obj);

            obj = pdf_dict_get(ctx, pdf_trailer(ctx, doc), PDF_NAME(ID));
            if (obj)
                pdf_dict_put(ctx, trailer, PDF_NAME(ID), obj);
        }
        if (main_xref_offset != 0)
        {
            nobj = pdf_new_int(ctx, main_xref_offset);
            pdf_dict_put_drop(ctx, trailer, PDF_NAME(Prev), nobj);
        }
    }

    fz_write_string(ctx, opts->out, "trailer\n");
    /* Trailer is NOT encrypted */
    pdf_print_obj(ctx, opts->out, trailer, opts->do_tight);
    fz_write_string(ctx, opts->out, "\n");

    pdf_drop_obj(ctx, trailer);

    fz_write_printf(ctx, opts->out, "startxref\n%lu\n%%%%EOF\n", startxref);

    doc->has_xref_streams = 0;
}

static void writexrefstreamsubsect(fz_context *ctx, pdf_document *doc, pdf_write_state *opts, pdf_obj *index, fz_buffer *fzbuf, int from, int to)
{
    int num;

    pdf_array_push_int(ctx, index, from);
    pdf_array_push_int(ctx, index, to - from);
    for (num = from; num < to; num++)
    {
        fz_append_byte(ctx, fzbuf, opts->use_list[num] ? 1 : 0);
        fz_append_byte(ctx, fzbuf, opts->ofs_list[num]>>24);
        fz_append_byte(ctx, fzbuf, opts->ofs_list[num]>>16);
        fz_append_byte(ctx, fzbuf, opts->ofs_list[num]>>8);
        fz_append_byte(ctx, fzbuf, opts->ofs_list[num]);
        fz_append_byte(ctx, fzbuf, opts->gen_list[num]);
    }
}

static void writexrefstream(fz_context *ctx, pdf_document *doc, pdf_write_state *opts, int from, int to, int first, int64_t main_xref_offset, int64_t startxref)
{
    int num;
    pdf_obj *dict = NULL;
    pdf_obj *obj;
    pdf_obj *w = NULL;
    pdf_obj *index;
    fz_buffer *fzbuf = NULL;

    fz_var(dict);
    fz_var(w);
    fz_var(fzbuf);
    fz_try(ctx)
    {
        num = pdf_create_object(ctx, doc);
        dict = pdf_new_dict(ctx, doc, 6);
        pdf_update_object(ctx, doc, num, dict);

        opts->first_xref_entry_offset = fz_tell_output(ctx, opts->out);

        to++;

        if (first)
        {
            obj = pdf_dict_get(ctx, pdf_trailer(ctx, doc), PDF_NAME(Info));
            if (obj)
                pdf_dict_put(ctx, dict, PDF_NAME(Info), obj);

            obj = pdf_dict_get(ctx, pdf_trailer(ctx, doc), PDF_NAME(Root));
            if (obj)
                pdf_dict_put(ctx, dict, PDF_NAME(Root), obj);

            obj = pdf_dict_get(ctx, pdf_trailer(ctx, doc), PDF_NAME(ID));
            if (obj)
                pdf_dict_put(ctx, dict, PDF_NAME(ID), obj);

            if (opts->do_incremental)
            {
                obj = pdf_dict_get(ctx, pdf_trailer(ctx, doc), PDF_NAME(Encrypt));
                if (obj)
                    pdf_dict_put(ctx, dict, PDF_NAME(Encrypt), obj);
            }
        }

        pdf_dict_put_int(ctx, dict, PDF_NAME(Size), to);

        if (opts->do_incremental)
        {
            pdf_dict_put_int(ctx, dict, PDF_NAME(Prev), doc->startxref);
            doc->startxref = startxref;
        }
        else
        {
            if (main_xref_offset != 0)
                pdf_dict_put_int(ctx, dict, PDF_NAME(Prev), main_xref_offset);
        }

        pdf_dict_put(ctx, dict, PDF_NAME(Type), PDF_NAME(XRef));

        w = pdf_new_array(ctx, doc, 3);
        pdf_dict_put(ctx, dict, PDF_NAME(W), w);
        pdf_array_push_int(ctx, w, 1);
        pdf_array_push_int(ctx, w, 4);
        pdf_array_push_int(ctx, w, 1);

        index = pdf_new_array(ctx, doc, 2);
        pdf_dict_put_drop(ctx, dict, PDF_NAME(Index), index);

        /* opts->gen_list[num] is already initialized by fz_calloc. */
        opts->use_list[num] = 1;
        opts->ofs_list[num] = opts->first_xref_entry_offset;

        fzbuf = fz_new_buffer(ctx, (1 + 4 + 1) * (to-from));

        if (opts->do_incremental)
        {
            int subfrom = from;
            int subto;

            while (subfrom < to)
            {
                while (subfrom < to && !pdf_xref_is_incremental(ctx, doc, subfrom))
                    subfrom++;

                subto = subfrom;
                while (subto < to && pdf_xref_is_incremental(ctx, doc, subto))
                    subto++;

                if (subfrom < subto)
                    writexrefstreamsubsect(ctx, doc, opts, index, fzbuf, subfrom, subto);

                subfrom = subto;
            }
        }
        else
        {
            writexrefstreamsubsect(ctx, doc, opts, index, fzbuf, from, to);
        }

        pdf_update_stream(ctx, doc, dict, fzbuf, 0);

        writeobject(ctx, doc, opts, num, 0, 0, 0);
        fz_write_printf(ctx, opts->out, "startxref\n%lu\n%%%%EOF\n", startxref);
    }
    fz_always(ctx)
    {
        pdf_drop_obj(ctx, dict);
        pdf_drop_obj(ctx, w);
        fz_drop_buffer(ctx, fzbuf);
    }
    fz_catch(ctx)
    {
        fz_rethrow(ctx);
    }

    doc->has_old_style_xrefs = 0;
}

static void
padto(fz_context *ctx, fz_output *out, int64_t target)
{
    int64_t pos = fz_tell_output(ctx, out);

    assert(pos <= target);
    while (pos < target)
    {
        fz_write_byte(ctx, out, '\n');
        pos++;
    }
}

static void
dowriteobject(fz_context *ctx, pdf_document *doc, pdf_write_state *opts, int num, int pass)
{
    pdf_xref_entry *entry = pdf_get_xref_entry(ctx, doc, num);
    if (entry->type == 'f')
        opts->gen_list[num] = entry->gen;
    if (entry->type == 'n')
        opts->gen_list[num] = entry->gen;
    if (entry->type == 'o')
        opts->gen_list[num] = 0;

    /* If we are renumbering, then make sure all generation numbers are
     * zero (except object 0 which must be free, and have a gen number of
     * 65535). Changing the generation numbers (and indeed object numbers)
     * will break encryption - so only do this if we are renumbering
     * anyway. */
    if (opts->do_garbage >= 2)
        opts->gen_list[num] = (num == 0 ? 65535 : 0);

    if (opts->do_garbage && !opts->use_list[num])
        return;

    if (entry->type == 'n' || entry->type == 'o')
    {
        if (pass > 0)
            padto(ctx, opts->out, opts->ofs_list[num]);
        if (!opts->do_incremental || pdf_xref_is_incremental(ctx, doc, num))
        {
            opts->ofs_list[num] = fz_tell_output(ctx, opts->out);
            writeobject(ctx, doc, opts, num, opts->gen_list[num], 1, num == opts->crypt_object_number);
        }
    }
    else
        opts->use_list[num] = 0;
}

static void
writeobjects(fz_context *ctx, pdf_document *doc, pdf_write_state *opts, int pass)
{
    int num;
    int xref_len = pdf_xref_len(ctx, doc);

    if (!opts->do_incremental)
    {
        fz_write_printf(ctx, opts->out, "%%PDF-%d.%d\n", doc->version / 10, doc->version % 10);
        fz_write_string(ctx, opts->out, "%\xC2\xB5\xC2\xB6\n\n");
    }

    dowriteobject(ctx, doc, opts, opts->start, pass);

    if (opts->do_linear)
    {
        /* Write first xref */
        if (pass == 0)
            opts->first_xref_offset = fz_tell_output(ctx, opts->out);
        else
            padto(ctx, opts->out, opts->first_xref_offset);
        writexref(ctx, doc, opts, opts->start, pdf_xref_len(ctx, doc), 1, opts->main_xref_offset, 0);
    }

    for (num = opts->start+1; num < xref_len; num++)
        dowriteobject(ctx, doc, opts, num, pass);
    if (opts->do_linear && pass == 1)
    {
        int64_t offset = (opts->start == 1 ? opts->main_xref_offset : opts->ofs_list[1] + opts->hintstream_len);
        padto(ctx, opts->out, offset);
    }
    for (num = 1; num < opts->start; num++)
    {
        if (pass == 1)
            opts->ofs_list[num] += opts->hintstream_len;
        dowriteobject(ctx, doc, opts, num, pass);
    }
}

static int
my_log2(int x)
{
    int i = 0;

    if (x <= 0)
        return 0;

    while ((1<<i) <= x && (1<<i) > 0)
        i++;

    if ((1<<i) <= 0)
        return 0;

    return i;
}

static void
make_page_offset_hints(fz_context *ctx, pdf_document *doc, pdf_write_state *opts, fz_buffer *buf)
{
    int i, j;
    int min_objs_per_page, max_objs_per_page;
    int min_page_length, max_page_length;
    int objs_per_page_bits;
    int min_shared_object, max_shared_object;
    int max_shared_object_refs = 0;
    int min_shared_length, max_shared_length;
    page_objects **pop = &opts->page_object_lists->page[0];
    int page_len_bits, shared_object_bits, shared_object_id_bits;
    int shared_length_bits;
    int xref_len = pdf_xref_len(ctx, doc);

    min_shared_object = pdf_xref_len(ctx, doc);
    max_shared_object = 1;
    min_shared_length = opts->file_len;
    max_shared_length = 0;
    for (i=1; i < xref_len; i++)
    {
        int min, max, page;

        min = opts->ofs_list[i];
        if (i == opts->start-1 || (opts->start == 1 && i == xref_len-1))
            max = opts->main_xref_offset;
        else if (i == xref_len-1)
            max = opts->ofs_list[1];
        else
            max = opts->ofs_list[i+1];

        assert(max > min);

        if (opts->use_list[i] & USE_SHARED)
        {
            page = -1;
            if (i < min_shared_object)
                min_shared_object = i;
            if (i > max_shared_object)
                max_shared_object = i;
            if (min_shared_length > max - min)
                min_shared_length = max - min;
            if (max_shared_length < max - min)
                max_shared_length = max - min;
        }
        else if (opts->use_list[i] & (USE_CATALOGUE | USE_HINTS | USE_PARAMS))
            page = -1;
        else if (opts->use_list[i] & USE_PAGE1)
        {
            page = 0;
            if (min_shared_length > max - min)
                min_shared_length = max - min;
            if (max_shared_length < max - min)
                max_shared_length = max - min;
        }
        else if (opts->use_list[i] == 0)
            page = -1;
        else
            page = opts->use_list[i]>>USE_PAGE_SHIFT;

        if (page >= 0)
        {
            pop[page]->num_objects++;
            if (pop[page]->min_ofs > min)
                pop[page]->min_ofs = min;
            if (pop[page]->max_ofs < max)
                pop[page]->max_ofs = max;
        }
    }

    min_objs_per_page = max_objs_per_page = pop[0]->num_objects;
    min_page_length = max_page_length = pop[0]->max_ofs - pop[0]->min_ofs;
    for (i=1; i < opts->page_count; i++)
    {
        int tmp;
        if (min_objs_per_page > pop[i]->num_objects)
            min_objs_per_page = pop[i]->num_objects;
        if (max_objs_per_page < pop[i]->num_objects)
            max_objs_per_page = pop[i]->num_objects;
        tmp = pop[i]->max_ofs - pop[i]->min_ofs;
        if (tmp < min_page_length)
            min_page_length = tmp;
        if (tmp > max_page_length)
            max_page_length = tmp;
    }

    for (i=0; i < opts->page_count; i++)
    {
        int count = 0;
        page_objects *po = opts->page_object_lists->page[i];
        for (j = 0; j < po->len; j++)
        {
            if (i == 0 && opts->use_list[po->object[j]] & USE_PAGE1)
                count++;
            else if (i != 0 && opts->use_list[po->object[j]] & USE_SHARED)
                count++;
        }
        po->num_shared = count;
        if (i == 0 || count > max_shared_object_refs)
            max_shared_object_refs = count;
    }
    if (min_shared_object > max_shared_object)
        min_shared_object = max_shared_object = 0;

    /* Table F.3 - Header */
    /* Header Item 1: Least number of objects in a page */
    fz_append_bits(ctx, buf, min_objs_per_page, 32);
    /* Header Item 2: Location of first pages page object */
    fz_append_bits(ctx, buf, opts->ofs_list[pop[0]->page_object_number], 32);
    /* Header Item 3: Number of bits required to represent the difference
     * between the greatest and least number of objects in a page. */
    objs_per_page_bits = my_log2(max_objs_per_page - min_objs_per_page);
    fz_append_bits(ctx, buf, objs_per_page_bits, 16);
    /* Header Item 4: Least length of a page. */
    fz_append_bits(ctx, buf, min_page_length, 32);
    /* Header Item 5: Number of bits needed to represent the difference
     * between the greatest and least length of a page. */
    page_len_bits = my_log2(max_page_length - min_page_length);
    fz_append_bits(ctx, buf, page_len_bits, 16);
    /* Header Item 6: Least offset to start of content stream (Acrobat
     * sets this to always be 0) */
    fz_append_bits(ctx, buf, 0, 32);
    /* Header Item 7: Number of bits needed to represent the difference
     * between the greatest and least offset to content stream (Acrobat
     * sets this to always be 0) */
    fz_append_bits(ctx, buf, 0, 16);
    /* Header Item 8: Least content stream length. (Acrobat
     * sets this to always be 0) */
    fz_append_bits(ctx, buf, 0, 32);
    /* Header Item 9: Number of bits needed to represent the difference
     * between the greatest and least content stream length (Acrobat
     * sets this to always be the same as item 5) */
    fz_append_bits(ctx, buf, page_len_bits, 16);
    /* Header Item 10: Number of bits needed to represent the greatest
     * number of shared object references. */
    shared_object_bits = my_log2(max_shared_object_refs);
    fz_append_bits(ctx, buf, shared_object_bits, 16);
    /* Header Item 11: Number of bits needed to represent the greatest
     * shared object identifier. */
    shared_object_id_bits = my_log2(max_shared_object - min_shared_object + pop[0]->num_shared);
    fz_append_bits(ctx, buf, shared_object_id_bits, 16);
    /* Header Item 12: Number of bits needed to represent the numerator
     * of the fractions. We always send 0. */
    fz_append_bits(ctx, buf, 0, 16);
    /* Header Item 13: Number of bits needed to represent the denominator
     * of the fractions. We always send 0. */
    fz_append_bits(ctx, buf, 0, 16);

    /* Table F.4 - Page offset hint table (per page) */
    /* Item 1: A number that, when added to the least number of objects
     * on a page, gives the number of objects in the page. */
    for (i = 0; i < opts->page_count; i++)
    {
        fz_append_bits(ctx, buf, pop[i]->num_objects - min_objs_per_page, objs_per_page_bits);
    }
    fz_append_bits_pad(ctx, buf);
    /* Item 2: A number that, when added to the least page length, gives
     * the length of the page in bytes. */
    for (i = 0; i < opts->page_count; i++)
    {
        fz_append_bits(ctx, buf, pop[i]->max_ofs - pop[i]->min_ofs - min_page_length, page_len_bits);
    }
    fz_append_bits_pad(ctx, buf);
    /* Item 3: The number of shared objects referenced from the page. */
    for (i = 0; i < opts->page_count; i++)
    {
        fz_append_bits(ctx, buf, pop[i]->num_shared, shared_object_bits);
    }
    fz_append_bits_pad(ctx, buf);
    /* Item 4: Shared object id for each shared object ref in every page.
     * Spec says "not for page 1", but acrobat does send page 1's - all
     * as zeros. */
    for (i = 0; i < opts->page_count; i++)
    {
        for (j = 0; j < pop[i]->len; j++)
        {
            int o = pop[i]->object[j];
            if (i == 0 && opts->use_list[o] & USE_PAGE1)
                fz_append_bits(ctx, buf, 0 /* o - pop[0]->page_object_number */, shared_object_id_bits);
            if (i != 0 && opts->use_list[o] & USE_SHARED)
                fz_append_bits(ctx, buf, o - min_shared_object + pop[0]->num_shared, shared_object_id_bits);
        }
    }
    fz_append_bits_pad(ctx, buf);
    /* Item 5: Numerator of fractional position for each shared object reference. */
    /* We always send 0 in 0 bits */
    /* Item 6: A number that, when added to the least offset to the start
     * of the content stream (F.3 Item 6), gives the offset in bytes of
     * start of the pages content stream object relative to the beginning
     * of the page. Always 0 in 0 bits. */
    /* Item 7: A number that, when added to the least content stream length
     * (F.3 Item 8), gives the length of the pages content stream object.
     * Always == Item 2 as least content stream length = least page stream
     * length.
     */
    for (i = 0; i < opts->page_count; i++)
    {
        fz_append_bits(ctx, buf, pop[i]->max_ofs - pop[i]->min_ofs - min_page_length, page_len_bits);
    }

    /* Pad, and then do shared object hint table */
    fz_append_bits_pad(ctx, buf);
    opts->hints_shared_offset = (int)fz_buffer_storage(ctx, buf, NULL);

    /* Table F.5: */
    /* Header Item 1: Object number of the first object in the shared
     * objects section. */
    fz_append_bits(ctx, buf, min_shared_object, 32);
    /* Header Item 2: Location of first object in the shared objects
     * section. */
    fz_append_bits(ctx, buf, opts->ofs_list[min_shared_object], 32);
    /* Header Item 3: The number of shared object entries for the first
     * page. */
    fz_append_bits(ctx, buf, pop[0]->num_shared, 32);
    /* Header Item 4: The number of shared object entries for the shared
     * objects section + first page. */
    fz_append_bits(ctx, buf, max_shared_object - min_shared_object + pop[0]->num_shared, 32);
    /* Header Item 5: The number of bits needed to represent the greatest
     * number of objects in a shared object group (Always 0). */
    fz_append_bits(ctx, buf, 0, 16);
    /* Header Item 6: The least length of a shared object group in bytes. */
    fz_append_bits(ctx, buf, min_shared_length, 32);
    /* Header Item 7: The number of bits required to represent the
     * difference between the greatest and least length of a shared object
     * group. */
    shared_length_bits = my_log2(max_shared_length - min_shared_length);
    fz_append_bits(ctx, buf, shared_length_bits, 16);

    /* Table F.6 */
    /* Item 1: Shared object group length (page 1 objects) */
    for (j = 0; j < pop[0]->len; j++)
    {
        int o = pop[0]->object[j];
        int64_t min, max;
        min = opts->ofs_list[o];
        if (o == opts->start-1)
            max = opts->main_xref_offset;
        else if (o < xref_len-1)
            max = opts->ofs_list[o+1];
        else
            max = opts->ofs_list[1];
        if (opts->use_list[o] & USE_PAGE1)
            fz_append_bits(ctx, buf, max - min - min_shared_length, shared_length_bits);
    }
    /* Item 1: Shared object group length (shared objects) */
    for (i = min_shared_object; i <= max_shared_object; i++)
    {
        int min, max;
        min = opts->ofs_list[i];
        if (i == opts->start-1)
            max = opts->main_xref_offset;
        else if (i < xref_len-1)
            max = opts->ofs_list[i+1];
        else
            max = opts->ofs_list[1];
        fz_append_bits(ctx, buf, max - min - min_shared_length, shared_length_bits);
    }
    fz_append_bits_pad(ctx, buf);

    /* Item 2: MD5 presence flags */
    for (i = max_shared_object - min_shared_object + pop[0]->num_shared; i > 0; i--)
    {
        fz_append_bits(ctx, buf, 0, 1);
    }
    fz_append_bits_pad(ctx, buf);
    /* Item 3: MD5 sums (not present) */
    fz_append_bits_pad(ctx, buf);
    /* Item 4: Number of objects in the group (not present) */
}

static void
make_hint_stream(fz_context *ctx, pdf_document *doc, pdf_write_state *opts)
{
    fz_buffer *buf = fz_new_buffer(ctx, 100);

    fz_try(ctx)
    {
        make_page_offset_hints(ctx, doc, opts, buf);
        pdf_update_stream(ctx, doc, pdf_load_object(ctx, doc, pdf_xref_len(ctx, doc)-1), buf, 0);
        opts->hintstream_len = (int)fz_buffer_storage(ctx, buf, NULL);
        fz_drop_buffer(ctx, buf);
    }
    fz_catch(ctx)
    {
        fz_drop_buffer(ctx, buf);
        fz_rethrow(ctx);
    }
}

static void presize_unsaved_signature_byteranges(fz_context *ctx, pdf_document *doc)
{
    int s;

    for (s = 0; s < doc->num_incremental_sections; s++)
    {
        pdf_xref *xref = &doc->xref_sections[s];

        if (xref->unsaved_sigs)
        {
            /* The ByteRange objects of signatures are initially written out with
            * dummy values, and then overwritten later. We need to make sure their
            * initial form at least takes enough sufficient file space */
            pdf_unsaved_sig *usig;
            int n = 0;

            for (usig = xref->unsaved_sigs; usig; usig = usig->next)
                n++;

            for (usig = xref->unsaved_sigs; usig; usig = usig->next)
            {
                /* There will be segments of bytes at the beginning, at
                * the end and between each consecutive pair of signatures,
                * hence n + 1 */
                int i;
                pdf_obj *byte_range = pdf_dict_getl(ctx, usig->field, PDF_NAME(V), PDF_NAME(ByteRange), NULL);

                for (i = 0; i < n+1; i++)
                {
                    pdf_array_push_int(ctx, byte_range, INT_MAX);
                    pdf_array_push_int(ctx, byte_range, INT_MAX);
                }
            }
        }
    }
}

static void complete_signatures(fz_context *ctx, pdf_document *doc, pdf_write_state *opts)
{
    pdf_unsaved_sig *usig;
    char *buf = NULL;
    int buf_size;
    int s;
    int i;
    int last_end;
    fz_stream *stm = NULL;
    fz_var(stm);
    fz_var(buf);

    fz_try(ctx)
    {
        for (s = 0; s < doc->num_incremental_sections; s++)
        {
            pdf_xref *xref = &doc->xref_sections[doc->num_incremental_sections - s - 1];

            if (xref->unsaved_sigs)
            {
                pdf_obj *byte_range;
                buf_size = 0;

                for (usig = xref->unsaved_sigs; usig; usig = usig->next)
                {
                    int size = usig->signer->max_digest_size(usig->signer);

                    buf_size = fz_maxi(buf_size, size);
                }

                buf_size = buf_size * 2 + SIG_EXTRAS_SIZE;

                buf = fz_calloc(ctx, buf_size, 1);

                stm = fz_stream_from_output(ctx, opts->out);
                /* Locate the byte ranges and contents in the saved file */
                for (usig = xref->unsaved_sigs; usig; usig = usig->next)
                {
                    char *bstr, *cstr, *fstr;
                    int pnum = pdf_obj_parent_num(ctx, pdf_dict_getl(ctx, usig->field, PDF_NAME(V), PDF_NAME(ByteRange), NULL));
                    fz_seek(ctx, stm, opts->ofs_list[pnum], SEEK_SET);
                    (void)fz_read(ctx, stm, (unsigned char *)buf, buf_size);
                    buf[buf_size-1] = 0;

                    bstr = strstr(buf, "/ByteRange");
                    cstr = strstr(buf, "/Contents");
                    fstr = strstr(buf, "/Filter");

                    if (bstr && cstr && fstr && bstr < cstr && cstr < fstr)
                    {
                        usig->byte_range_start = bstr - buf + 10 + opts->ofs_list[pnum];
                        usig->byte_range_end = cstr - buf + opts->ofs_list[pnum];
                        usig->contents_start = cstr - buf + 9 + opts->ofs_list[pnum];
                        usig->contents_end = fstr - buf + opts->ofs_list[pnum];
                    }
                }

                fz_drop_stream(ctx, stm);
                stm = NULL;

                /* Recreate ByteRange with correct values. Initially store the
                * recreated object in the first of the unsaved signatures */
                byte_range = pdf_new_array(ctx, doc, 4);
                pdf_dict_putl_drop(ctx, xref->unsaved_sigs->field, byte_range, PDF_NAME(V), PDF_NAME(ByteRange), NULL);

                last_end = 0;
                for (usig = xref->unsaved_sigs; usig; usig = usig->next)
                {
                    pdf_array_push_int(ctx, byte_range, last_end);
                    pdf_array_push_int(ctx, byte_range, usig->contents_start - last_end);
                    last_end = usig->contents_end;
                }
                pdf_array_push_int(ctx, byte_range, last_end);
                pdf_array_push_int(ctx, byte_range, xref->end_ofs - last_end);

                /* Copy the new ByteRange to the other unsaved signatures */
                for (usig = xref->unsaved_sigs->next; usig; usig = usig->next)
                    pdf_dict_putl_drop(ctx, usig->field, pdf_copy_array(ctx, byte_range), PDF_NAME(V), PDF_NAME(ByteRange), NULL);

                /* Write the byte range into buf, padding with spaces*/
                i = pdf_sprint_obj(ctx, buf, buf_size, byte_range, 1);
                memset(buf+i, ' ', buf_size-i);

                /* Write the byte range to the file */
                for (usig = xref->unsaved_sigs; usig; usig = usig->next)
                {
                    fz_seek_output(ctx, opts->out, usig->byte_range_start, SEEK_SET);
                    fz_write_data(ctx, opts->out, buf, usig->byte_range_end - usig->byte_range_start);
                }

                /* Write the digests into the file */
                for (usig = xref->unsaved_sigs; usig; usig = usig->next)
                    pdf_write_digest(ctx, opts->out, byte_range, usig->contents_start, usig->contents_end - usig->contents_start, usig->signer);

                /* delete the unsaved_sigs records */
                while ((usig = xref->unsaved_sigs) != NULL)
                {
                    xref->unsaved_sigs = usig->next;
                    pdf_drop_obj(ctx, usig->field);
                    usig->signer->drop(usig->signer);
                    fz_free(ctx, usig);
                }

                xref->unsaved_sigs_end = NULL;

                fz_free(ctx, buf);
                buf = NULL;
            }
        }
    }
    fz_catch(ctx)
    {
        fz_drop_stream(ctx, stm);
        fz_free(ctx, buf);
        fz_rethrow(ctx);
    }
}

static void clean_content_streams(fz_context *ctx, pdf_document *doc, int sanitize, int ascii)
{
    int n = pdf_count_pages(ctx, doc);
    int i;

    for (i = 0; i < n; i++)
    {
        pdf_annot *annot;
        pdf_page *page = pdf_load_page(ctx, doc, i);
        pdf_clean_page_contents(ctx, doc, page, NULL, NULL, NULL, sanitize, ascii);

        for (annot = pdf_first_annot(ctx, page); annot != NULL; annot = pdf_next_annot(ctx, annot))
        {
            pdf_clean_annot_contents(ctx, doc, annot, NULL, NULL, NULL, sanitize, ascii);
        }

        fz_drop_page(ctx, &page->super);
    }
}

/* Initialise the pdf_write_state, used dynamically during the write, from the static
 * pdf_write_options, passed into pdf_save_document */
static void initialise_write_state(fz_context *ctx, pdf_document *doc, const pdf_write_options *in_opts, pdf_write_state *opts)
{
    int xref_len = pdf_xref_len(ctx, doc);

    opts->do_incremental = in_opts->do_incremental;
    opts->do_ascii = in_opts->do_ascii;
    opts->do_tight = !in_opts->do_pretty;
    opts->do_expand = in_opts->do_decompress;
    opts->do_compress = in_opts->do_compress;
    opts->do_compress_images = in_opts->do_compress_images;
    opts->do_compress_fonts = in_opts->do_compress_fonts;

    opts->do_garbage = in_opts->do_garbage;
    opts->do_linear = in_opts->do_linear;
    opts->do_clean = in_opts->do_clean;
    opts->start = 0;
    opts->main_xref_offset = INT_MIN;

    /* We deliberately make these arrays long enough to cope with
    * 1 to n access rather than 0..n-1, and add space for 2 new
    * extra entries that may be required for linearization. */
    opts->list_len = 0;
    opts->use_list = NULL;
    opts->ofs_list = NULL;
    opts->gen_list = NULL;
    opts->renumber_map = NULL;
    opts->rev_renumber_map = NULL;
    opts->continue_on_error = in_opts->continue_on_error;
    opts->errors = in_opts->errors;

    expand_lists(ctx, opts, xref_len);
}

/* Free the resources held by the dynamic write options */
static void finalise_write_state(fz_context *ctx, pdf_write_state *opts)
{
    fz_free(ctx, opts->use_list);
    fz_free(ctx, opts->ofs_list);
    fz_free(ctx, opts->gen_list);
    fz_free(ctx, opts->renumber_map);
    fz_free(ctx, opts->rev_renumber_map);
    pdf_drop_obj(ctx, opts->linear_l);
    pdf_drop_obj(ctx, opts->linear_h0);
    pdf_drop_obj(ctx, opts->linear_h1);
    pdf_drop_obj(ctx, opts->linear_o);
    pdf_drop_obj(ctx, opts->linear_e);
    pdf_drop_obj(ctx, opts->linear_n);
    pdf_drop_obj(ctx, opts->linear_t);
    pdf_drop_obj(ctx, opts->hints_s);
    pdf_drop_obj(ctx, opts->hints_length);
    page_objects_list_destroy(ctx, opts->page_object_lists);
}

static void
prepare_for_save(fz_context *ctx, pdf_document *doc, pdf_write_options *in_opts)
{
    doc->freeze_updates = 1;

    /* Rewrite (and possibly sanitize) the operator streams */
    if (in_opts->do_clean || in_opts->do_sanitize)
        clean_content_streams(ctx, doc, in_opts->do_sanitize, in_opts->do_ascii);

    pdf_finish_edit(ctx, doc);
    presize_unsaved_signature_byteranges(ctx, doc);
}

static void
change_identity(fz_context *ctx, pdf_document *doc)
{
    pdf_obj *identity = pdf_dict_get(ctx, pdf_trailer(ctx, doc), PDF_NAME(ID));
    pdf_obj *str;
    unsigned char rnd[16];

    if (pdf_array_len(ctx, identity) < 2)
        return;

    /* Maybe recalculate this in future. For now, just change the second one. */
    fz_memrnd(ctx, rnd, 16);
    str = pdf_new_string(ctx, (char *)rnd, 16);
    pdf_array_put_drop(ctx, identity, 1, str);

}

static void
do_pdf_save_document(fz_context *ctx, pdf_document *doc, pdf_write_state *opts, pdf_write_options *in_opts)
{
    int lastfree;
    int num;
    int xref_len;

    if (in_opts->do_incremental)
    {
        /* If no changes, nothing to write */
        if (doc->num_incremental_sections == 0)
            return;
        if (opts->out)
        {
            fz_seek_output(ctx, opts->out, 0, SEEK_END);
            fz_write_string(ctx, opts->out, "\n");
        }
    }

    xref_len = pdf_xref_len(ctx, doc);

    fz_try(ctx)
    {
        initialise_write_state(ctx, doc, in_opts, opts);

        /* Make sure any objects hidden in compressed streams have been loaded */
        if (!opts->do_incremental)
        {
            pdf_ensure_solid_xref(ctx, doc, xref_len);
            preloadobjstms(ctx, doc);
            change_identity(ctx, doc);
            xref_len = pdf_xref_len(ctx, doc); /* May have changed due to repair */
            expand_lists(ctx, opts, xref_len);
        }

        /* Sweep & mark objects from the trailer */
        if (opts->do_garbage >= 1 || opts->do_linear)
            (void)markobj(ctx, doc, opts, pdf_trailer(ctx, doc));
        else
        {
            xref_len = pdf_xref_len(ctx, doc); /* May have changed due to repair */
            expand_lists(ctx, opts, xref_len);
            for (num = 0; num < xref_len; num++)
                opts->use_list[num] = 1;
        }

        /* Coalesce and renumber duplicate objects */
        if (opts->do_garbage >= 3)
            removeduplicateobjs(ctx, doc, opts);

        /* Compact xref by renumbering and removing unused objects */
        if (opts->do_garbage >= 2 || opts->do_linear)
            compactxref(ctx, doc, opts);

        opts->crypt_object_number = 0;

        if (doc->crypt)
        {
            pdf_obj *crypt = pdf_dict_get(ctx, pdf_trailer(ctx, doc), PDF_NAME(Encrypt));
            int crypt_num = pdf_to_num(ctx, crypt);
            opts->crypt_object_number = opts->renumber_map[crypt_num];
        }

        /* Make renumbering affect all indirect references and update xref */
        if (opts->do_garbage >= 2 || opts->do_linear)
            renumberobjs(ctx, doc, opts);

        /* Truncate the xref after compacting and renumbering */
        if ((opts->do_garbage >= 2 || opts->do_linear) && !opts->do_incremental)
        {
            xref_len = pdf_xref_len(ctx, doc); /* May have changed due to repair */
            expand_lists(ctx, opts, xref_len);
            while (xref_len > 0 && !opts->use_list[xref_len-1])
                xref_len--;
        }

        if (opts->do_linear)
            linearize(ctx, doc, opts);

        if (opts->do_incremental)
        {
            int i;

            doc->disallow_new_increments = 1;

            for (i = 0; i < doc->num_incremental_sections; i++)
            {
                doc->xref_base = doc->num_incremental_sections - i - 1;

                writeobjects(ctx, doc, opts, 0);

                for (num = 0; num < xref_len; num++)
                {
                    if (!opts->use_list[num] && pdf_xref_is_incremental(ctx, doc, num))
                    {
                        /* Make unreusable. FIXME: would be better to link to existing free list */
                        opts->gen_list[num] = 65535;
                        opts->ofs_list[num] = 0;
                    }
                }

                opts->first_xref_offset = fz_tell_output(ctx, opts->out);
                if (doc->has_xref_streams)
                    writexrefstream(ctx, doc, opts, 0, xref_len, 1, 0, opts->first_xref_offset);
                else
                    writexref(ctx, doc, opts, 0, xref_len, 1, 0, opts->first_xref_offset);

                doc->xref_sections[doc->xref_base].end_ofs = fz_tell_output(ctx, opts->out);
            }

            doc->xref_base = 0;
            doc->disallow_new_increments = 0;
        }
        else
        {
            writeobjects(ctx, doc, opts, 0);

            /* Construct linked list of free object slots */
            lastfree = 0;
            for (num = 0; num < xref_len; num++)
            {
                if (!opts->use_list[num])
                {
                    opts->gen_list[num]++;
                    opts->ofs_list[lastfree] = num;
                    lastfree = num;
                }
            }

            if (opts->do_linear && opts->page_count > 0)
            {
                opts->main_xref_offset = fz_tell_output(ctx, opts->out);
                writexref(ctx, doc, opts, 0, opts->start, 0, 0, opts->first_xref_offset);
                opts->file_len = fz_tell_output(ctx, opts->out);

                make_hint_stream(ctx, doc, opts);
                if (opts->do_ascii)
                {
                    opts->hintstream_len *= 2;
                    opts->hintstream_len += 1 + ((opts->hintstream_len+63)>>6);
                }
                opts->file_len += opts->hintstream_len;
                opts->main_xref_offset += opts->hintstream_len;
                update_linearization_params(ctx, doc, opts);
                fz_seek_output(ctx, opts->out, 0, 0);
                writeobjects(ctx, doc, opts, 1);

                padto(ctx, opts->out, opts->main_xref_offset);
                writexref(ctx, doc, opts, 0, opts->start, 0, 0, opts->first_xref_offset);
            }
            else
            {
                opts->first_xref_offset = fz_tell_output(ctx, opts->out);
                writexref(ctx, doc, opts, 0, xref_len, 1, 0, opts->first_xref_offset);
            }

            doc->xref_sections[0].end_ofs = fz_tell_output(ctx, opts->out);
        }

        complete_signatures(ctx, doc, opts);

        doc->dirty = 0;
    }
    fz_always(ctx)
    {
        finalise_write_state(ctx, opts);

        doc->freeze_updates = 0;
    }
    fz_catch(ctx)
    {
        fz_rethrow(ctx);
    }
}

void JM_write_document(fz_context *ctx, pdf_document *doc, fz_output *out, pdf_write_options *in_opts, int decrypt)
{
    if (decrypt == 0)
    {
        pdf_write_document(ctx, doc, out, in_opts);
        return;
    }
    pdf_write_options opts_defaults = { 0 };
    pdf_write_state opts = { 0 };

    if (!doc)
        return;

    if (!in_opts)
        in_opts = &opts_defaults;

    if (in_opts->do_incremental && doc->repair_attempted)
        fz_throw(ctx, FZ_ERROR_GENERIC, "Can't do incremental writes on a repaired file");
    if (in_opts->do_incremental && in_opts->do_garbage)
        fz_throw(ctx, FZ_ERROR_GENERIC, "Can't do incremental writes with garbage collection");
    if (in_opts->do_incremental && in_opts->do_linear)
        fz_throw(ctx, FZ_ERROR_GENERIC, "Can't do incremental writes with linearisation");
    if (pdf_has_unsaved_sigs(ctx, doc) && !out->as_stream)
        fz_throw(ctx, FZ_ERROR_GENERIC, "Can't write pdf that has unsaved sigs to a fz_output unless it supports fz_stream_from_output!");

    prepare_for_save(ctx, doc, in_opts);

    opts.out = out;

    do_pdf_save_document(ctx, doc, &opts, in_opts);
}

void JM_save_document(fz_context *ctx, pdf_document *doc, const char *filename, pdf_write_options *in_opts, int decrypt)
{
    if (decrypt == 0)
    {
        pdf_save_document(ctx, doc, filename, in_opts);
        return;
    }
    pdf_write_options opts_defaults = { 0 };
    pdf_write_state opts = { 0 };

    if (!doc)
        return;

    if (!in_opts)
        in_opts = &opts_defaults;

    if (in_opts->do_incremental && !doc->file)
        fz_throw(ctx, FZ_ERROR_GENERIC, "Can't do incremental writes on a new document");
    if (in_opts->do_incremental && doc->repair_attempted)
        fz_throw(ctx, FZ_ERROR_GENERIC, "Can't do incremental writes on a repaired file");
    if (in_opts->do_incremental && in_opts->do_garbage)
        fz_throw(ctx, FZ_ERROR_GENERIC, "Can't do incremental writes with garbage collection");
    if (in_opts->do_incremental && in_opts->do_linear)
        fz_throw(ctx, FZ_ERROR_GENERIC, "Can't do incremental writes with linearisation");

    prepare_for_save(ctx, doc, in_opts);

    if (in_opts->do_incremental)
    {
        /* If no changes, nothing to write */
        if (doc->num_incremental_sections == 0)
            return;
        opts.out = fz_new_output_with_path(ctx, filename, 1);
    }
    else
    {
        opts.out = fz_new_output_with_path(ctx, filename, 0);
    }
    fz_try(ctx)
    {
        do_pdf_save_document(ctx, doc, &opts, in_opts);
        fz_close_output(ctx, opts.out);
    }
    fz_always(ctx)
    {
        fz_drop_output(ctx, opts.out);
        opts.out = NULL;
    }
    fz_catch(ctx)
    {
        fz_rethrow(ctx);
    }
}
%}