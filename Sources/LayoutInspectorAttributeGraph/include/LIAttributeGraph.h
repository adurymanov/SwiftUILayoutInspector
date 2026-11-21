#ifndef LIAttributeGraph_h
#define LIAttributeGraph_h

#include <stdint.h>
#include <stdbool.h>

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

#ifdef __cplusplus
}
#endif

#endif
