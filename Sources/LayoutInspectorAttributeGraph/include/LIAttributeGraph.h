#ifndef LIAttributeGraph_h
#define LIAttributeGraph_h

#include <stdint.h>
#include <stdbool.h>
#include <CoreFoundation/CoreFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Thin, dlsym-based bridge to the private AttributeGraph "tree element" API.
/// SwiftUI records one tree element per view / modifier / view list when SWIFTUI_VIEW_DEBUG is set.
/// `_ViewDebug.serializedData` drops view-list elements – and that is exactly where custom views
/// (ProfileHeader, StatsRow…) live – so we walk the tree ourselves to recover them.
typedef const void *LIAGTreeElement;

bool LIAGIsAvailable(void);
LIAGTreeElement _Nullable LIAGSubgraphGetTreeRoot(const void * _Nonnull subgraph);
const void * _Nullable LIAGTreeElementGetType(LIAGTreeElement _Nonnull element);
uint32_t LIAGTreeElementGetFlags(LIAGTreeElement _Nonnull element);
uint32_t LIAGTreeElementGetValue(LIAGTreeElement _Nonnull element);
/// `AGTypeDescription`: the type's name without module prefixes, as SwiftUI writes it to `readableType`.
/// NULL when the function is missing. The string is not released (one per type, callers keep it).
const void * _Nullable LIAGTypeDescription(const void * _Nonnull type);
/// Writes up to `max` children into `out`, returns the number of children written.
int LIAGTreeElementGetChildren(LIAGTreeElement _Nonnull element, LIAGTreeElement _Nullable * _Nonnull out, int max);

/// A walk over the trees of one graph that gives the same children as ``LIAGTreeElementGetChildren`` without asking
/// AttributeGraph for the subgraphs hung under an element that has none.
///
/// AttributeGraph hangs a subgraph's tree under the element that owns the node its tree root holds as value: for every
/// element, `AGTreeElementGetNextChild` checks every subgraph of the graph (`AG::Subgraph::tree_subgraph_child`),
/// which is most of a big screen's walk. The walk takes the values of all subgraphs' roots once and asks only
/// elements that own one of them (`AGTreeElementGetNextChild2(it, false)` for the rest). Only where the code of those
/// functions is the code this was written against (the iOS 26.5 and 27.0 simulators, checked by a hash of the
/// instructions): NULL otherwise, and then the plain children are read.
typedef struct LIAGChildWalk LIAGChildWalk;
bool LIAGChildWalkIsAvailable(void);
LIAGChildWalk * _Nullable LIAGChildWalkCreate(const void * _Nonnull subgraph);
int LIAGChildWalkGetChildren(LIAGChildWalk * _Nonnull walk, LIAGTreeElement _Nonnull element, LIAGTreeElement _Nullable * _Nonnull out, int max);
/// Elements the walk asked about subgraphs, and the subgraph roots it knew of (diagnostics).
void LIAGChildWalkGetStats(LIAGChildWalk * _Nonnull walk, int * _Nonnull searched, int * _Nonnull roots);
void LIAGChildWalkDestroy(LIAGChildWalk * _Nonnull walk);
/// The 8 hashes the code check computed, `0` for a function it didn't get to (diagnostics: to add an iOS version).
void LIAGChildWalkCodeHashes(uint64_t * _Nonnull out);

/// Profiling of attribute updates, for counting `body` evaluations. `false` when a symbol is missing.
bool LIAGProfilingIsAvailable(void);
const void * _Nullable LIAGSubgraphGetGraph(const void * _Nonnull subgraph);
/// `NULL` – every graph in the process.
void LIAGGraphStartProfiling(const void * _Nullable graph);
void LIAGGraphStopProfiling(const void * _Nullable graph);
void LIAGGraphResetProfile(const void * _Nullable graph);
/// `AGGraphGetCounter`; 5 is the graph's id (shared by the graph contexts of one graph).
uint64_t LIAGGraphGetCounter(const void * _Nonnull graph, uint32_t counter);
/// `AGGraphDescription`: with `format: graph/dict` a dictionary of the graph's nodes, types and tree elements.
CFTypeRef _Nullable LIAGGraphDescription(const void * _Nonnull graph, CFDictionaryRef _Nonnull options);
/// `AGGraphGetValue`: the value of `attribute`, whose type is `type` (Swift metadata). `NULL` when unavailable, and
/// when the value is out of date: reading it then would run the rule that computes it (a view's parent body).
const void * _Nullable LIAGGraphGetValue(uint32_t attribute, const void * _Nonnull type);
/// The attribute an indirect attribute reads from (`AGGraphGetIndirectAttribute`), the attribute itself otherwise. A
/// view element's value resolves to the `body` node of the view that built it.
uint32_t LIAGGraphGetIndirectAttribute(uint32_t attribute);
/// The attribute SwiftUI recorded under `key` (`"position"`, `"size"`) for an element, and its type; 0 when there is
/// none. Recorded only for the `SWIFTUI_VIEW_DEBUG` properties.
uint32_t LIAGTreeElementGetValueNamed(LIAGTreeElement _Nonnull element, const char * _Nonnull key, const void * _Nullable * _Nonnull type);
/// Both recorded geometry attributes of an element in one pass over its values; `false` unless both are there.
bool LIAGTreeElementGetGeometry(LIAGTreeElement _Nonnull element, uint32_t * _Nonnull position, const void * _Nullable * _Nonnull positionType,
                                uint32_t * _Nonnull size, const void * _Nullable * _Nonnull sizeType);
/// Writes up to `max` attributes (the graph nodes) an element owns into `out`, returns how many were written.
int LIAGTreeElementGetNodes(LIAGTreeElement _Nonnull element, uint32_t * _Nonnull out, int max);
/// `AGGraphGetAttributeInfo`: the Swift metadata of the rule that computes `attribute` (`StaticBody<ViewBodyAccessor<V>, …>`
/// for a view's `body`) and of its value. `false` when the function is missing or the attribute isn't a direct one.
bool LIAGGraphGetAttributeTypes(uint32_t attribute, const void * _Nullable * _Nonnull ruleType, const void * _Nullable * _Nonnull valueType);
/// `AGGraphGetAttributeInfo` is there: ``LIAGGraphGetAttributeTypes`` can answer.
bool LIAGAttributeTypesAreAvailable(void);

#ifdef __cplusplus
}
#endif

#endif
