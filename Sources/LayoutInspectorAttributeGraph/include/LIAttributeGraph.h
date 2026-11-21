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
/// Writes up to `max` attributes (the graph nodes) an element owns into `out`, returns how many were written.
int LIAGTreeElementGetNodes(LIAGTreeElement _Nonnull element, uint32_t * _Nonnull out, int max);

#ifdef __cplusplus
}
#endif

#endif
