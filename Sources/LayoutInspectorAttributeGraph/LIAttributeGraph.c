#include "LIAttributeGraph.h"

// LAYOUT_INSPECTOR_DISABLED compiles the bridge out, like a disabled `LayoutInspectorEngine` trait: no dlsym
// names and no load-time constructor. For hosts that keep the trait on but must not ship private API in some
// build configurations (set it in GCC_PREPROCESSOR_DEFINITIONS there).
#ifndef LAYOUT_INSPECTOR_DISABLED
#include <dlfcn.h>
#include <string.h>

// Real struct is { subgraph, element, nextChild, bool iteratedSubgraph, size_t subgraphIndex } (40 bytes).
// Declared larger on purpose: any size > 16 bytes is returned indirectly on arm64/x86_64, offsets match.
typedef struct { uint64_t storage[8]; } LIChildIterator;

typedef LIAGTreeElement (*GetTreeRootFn)(const void *);
typedef const void *(*GetTypeFn)(LIAGTreeElement);
typedef uint32_t (*GetU32Fn)(LIAGTreeElement);
typedef LIChildIterator (*MakeChildIteratorFn)(LIAGTreeElement);
typedef LIAGTreeElement (*NextChildFn)(LIChildIterator *);

static GetTreeRootFn getTreeRoot;
static GetTypeFn getType;
static GetU32Fn getFlags;
static GetU32Fn getValue;
static MakeChildIteratorFn makeChildIterator;
static NextChildFn nextChild;
typedef const void *(*TypeDescriptionFn)(const void *);
static TypeDescriptionFn typeDescription;

// { element, node index } – returned in registers on arm64 and x86_64.
typedef struct { const void *element; uint64_t index; } LINodeIterator;
typedef LINodeIterator (*MakeNodeIteratorFn)(LIAGTreeElement);
typedef uint32_t (*NextNodeFn)(LINodeIterator *);
typedef const void *(*SubgraphGetGraphFn)(const void *);
typedef void (*GraphFn)(const void *);
typedef uint64_t (*GraphCounterFn)(const void *, uint32_t);
typedef CFTypeRef (*GraphDescriptionFn)(const void *, CFDictionaryRef);
// { value, changed } – returned in registers.
typedef struct { const void *value; bool changed; } LIValue;
typedef LIValue (*GraphGetValueFn)(uint32_t, uint32_t, const void *);
typedef uint8_t (*GraphGetValueStateFn)(uint32_t);
static GraphGetValueFn graphGetValue;
static GraphGetValueStateFn graphGetValueState;
// { element, next value } – returned in registers.
typedef struct { const void *element; const void *next; } LIValueIterator;
typedef LIValueIterator (*MakeValueIteratorFn)(LIAGTreeElement);
typedef const void *(*NextValueFn)(LIValueIterator *);
typedef const char *(*TreeValueKeyFn)(const void *);
typedef uint32_t (*TreeValueValueFn)(const void *);
typedef const void *(*TreeValueTypeFn)(const void *);
typedef uint32_t (*IndirectFn)(uint32_t);
static MakeValueIteratorFn makeValueIterator;
static NextValueFn nextValue;
static TreeValueKeyFn treeValueKey;
static TreeValueValueFn treeValueValue;
static TreeValueTypeFn treeValueType;
static IndirectFn graphGetIndirectAttribute;
// { const AGAttributeType *type; const void *body; } – returned in registers. AGAttributeType starts with the rule's
// type id (Swift metadata), then the value's.
typedef struct { const void *const *type; const void *body; } LIAttributeInfo;
typedef LIAttributeInfo (*AttributeInfoFn)(uint32_t);
static AttributeInfoFn graphGetAttributeInfo;
typedef uint32_t (*SubgraphChildCountFn)(const void *);
typedef const void *(*SubgraphChildFn)(const void *, uint32_t, uint8_t *);
typedef LIAGTreeElement (*TreeElementParentFn)(LIAGTreeElement);
static SubgraphChildCountFn subgraphGetChildCount;
static SubgraphChildFn subgraphGetChild;
static TreeElementParentFn treeElementGetParent;

static MakeNodeIteratorFn makeNodeIterator;
static NextNodeFn nextNode;
static SubgraphGetGraphFn subgraphGetGraph;
static GraphFn startProfiling;
static GraphFn stopProfiling;
static GraphFn resetProfile;
static GraphCounterFn graphCounter;
static GraphDescriptionFn graphDescription;

static void resolve(void) {
    static bool resolved = false;
    if (resolved) return;
    resolved = true;
    void *h = dlopen(NULL, RTLD_NOW);
    getTreeRoot = (GetTreeRootFn)dlsym(h, "AGSubgraphGetTreeRoot");
    getType = (GetTypeFn)dlsym(h, "AGTreeElementGetType");
    getFlags = (GetU32Fn)dlsym(h, "AGTreeElementGetFlags");
    getValue = (GetU32Fn)dlsym(h, "AGTreeElementGetValue");
    makeChildIterator = (MakeChildIteratorFn)dlsym(h, "AGTreeElementMakeChildIterator");
    nextChild = (NextChildFn)dlsym(h, "AGTreeElementGetNextChild");
    typeDescription = (TypeDescriptionFn)dlsym(h, "AGTypeDescription");
    makeNodeIterator = (MakeNodeIteratorFn)dlsym(h, "AGTreeElementMakeNodeIterator");
    nextNode = (NextNodeFn)dlsym(h, "AGTreeElementGetNextNode");
    subgraphGetGraph = (SubgraphGetGraphFn)dlsym(h, "AGSubgraphGetGraph");
    startProfiling = (GraphFn)dlsym(h, "AGGraphStartProfiling");
    stopProfiling = (GraphFn)dlsym(h, "AGGraphStopProfiling");
    resetProfile = (GraphFn)dlsym(h, "AGGraphResetProfile");
    graphCounter = (GraphCounterFn)dlsym(h, "AGGraphGetCounter");
    graphDescription = (GraphDescriptionFn)dlsym(h, "AGGraphDescription");
    graphGetValue = (GraphGetValueFn)dlsym(h, "AGGraphGetValue");
    graphGetValueState = (GraphGetValueStateFn)dlsym(h, "AGGraphGetValueState");
    makeValueIterator = (MakeValueIteratorFn)dlsym(h, "AGTreeElementMakeValueIterator");
    nextValue = (NextValueFn)dlsym(h, "AGTreeElementGetNextValue");
    treeValueKey = (TreeValueKeyFn)dlsym(h, "AGTreeValueGetKey");
    treeValueValue = (TreeValueValueFn)dlsym(h, "AGTreeValueGetValue");
    treeValueType = (TreeValueTypeFn)dlsym(h, "AGTreeValueGetType");
    graphGetIndirectAttribute = (IndirectFn)dlsym(h, "AGGraphGetIndirectAttribute");
    graphGetAttributeInfo = (AttributeInfoFn)dlsym(h, "AGGraphGetAttributeInfo");
    subgraphGetChildCount = (SubgraphChildCountFn)dlsym(h, "AGSubgraphGetChildCount");
    subgraphGetChild = (SubgraphChildFn)dlsym(h, "AGSubgraphGetChild");
    treeElementGetParent = (TreeElementParentFn)dlsym(h, "AGTreeElementGetParent");
}

bool LIAGIsAvailable(void) {
    resolve();
    return getTreeRoot && getType && getFlags && getValue && makeChildIterator && nextChild;
}

LIAGTreeElement LIAGSubgraphGetTreeRoot(const void *subgraph) {
    return LIAGIsAvailable() ? getTreeRoot(subgraph) : NULL;
}

const void *LIAGTreeElementGetType(LIAGTreeElement element) {
    return LIAGIsAvailable() ? getType(element) : NULL;
}

uint32_t LIAGTreeElementGetFlags(LIAGTreeElement element) {
    return LIAGIsAvailable() ? getFlags(element) : 0;
}

uint32_t LIAGTreeElementGetValue(LIAGTreeElement element) {
    return LIAGIsAvailable() ? getValue(element) : 0;
}

const void *LIAGTypeDescription(const void *type) {
    resolve();
    return typeDescription ? typeDescription(type) : NULL;
}

int LIAGTreeElementGetChildren(LIAGTreeElement element, LIAGTreeElement *out, int max) {
    return LIAGTreeElementGetChildrenIncludingSubgraphs(element, out, max, true);
}

int LIAGTreeElementGetChildrenIncludingSubgraphs(LIAGTreeElement element, LIAGTreeElement *out, int max, bool subgraphs) {
    if (!LIAGIsAvailable()) return 0;
    LIChildIterator it;
    memset(&it, 0, sizeof(it));
    it = makeChildIterator(element);
    // `iteratedSubgraph` (offset 24): the iterator then stops after the element's own children.
    if (!subgraphs) ((uint8_t *)&it)[24] = 1;
    int n = 0;
    LIAGTreeElement child;
    while (n < max && (child = nextChild(&it)) != NULL) {
        out[n++] = child;
    }
    return n;
}

bool LIAGSubgraphChildrenAreAvailable(void) {
    resolve();
    return subgraphGetChildCount && subgraphGetChild && treeElementGetParent && getTreeRoot;
}

uint32_t LIAGSubgraphGetChildCount(const void *subgraph) {
    return LIAGSubgraphChildrenAreAvailable() ? subgraphGetChildCount(subgraph) : 0;
}

const void *LIAGSubgraphGetChild(const void *subgraph, uint32_t index) {
    if (!LIAGSubgraphChildrenAreAvailable()) return NULL;
    uint8_t tag = 0;
    return subgraphGetChild(subgraph, index, &tag);
}

LIAGTreeElement LIAGTreeElementGetParent(LIAGTreeElement element) {
    return LIAGSubgraphChildrenAreAvailable() ? treeElementGetParent(element) : NULL;
}

// MARK: - Profiling

bool LIAGProfilingIsAvailable(void) {
    resolve();
    return LIAGIsAvailable() && makeNodeIterator && nextNode && subgraphGetGraph && startProfiling && stopProfiling
        && resetProfile && graphCounter && graphDescription;
}

const void *LIAGSubgraphGetGraph(const void *subgraph) {
    return LIAGProfilingIsAvailable() ? subgraphGetGraph(subgraph) : NULL;
}

void LIAGGraphStartProfiling(const void *graph) { if (LIAGProfilingIsAvailable()) startProfiling(graph); }
void LIAGGraphStopProfiling(const void *graph) { if (LIAGProfilingIsAvailable()) stopProfiling(graph); }
void LIAGGraphResetProfile(const void *graph) { if (LIAGProfilingIsAvailable()) resetProfile(graph); }

uint64_t LIAGGraphGetCounter(const void *graph, uint32_t counter) {
    return LIAGProfilingIsAvailable() ? graphCounter(graph, counter) : 0;
}

CFTypeRef LIAGGraphDescription(const void *graph, CFDictionaryRef options) {
    return LIAGProfilingIsAvailable() ? graphDescription(graph, options) : NULL;
}

const void *LIAGGraphGetValue(uint32_t attribute, const void *type) {
    resolve();
    if (!graphGetValue || !graphGetValueState) return NULL;
    // 2 is AGAttributeNil.
    if (attribute == 0 || attribute == 2) return NULL;
    // AGValueState: dirty 1, pending 2, updating 4, value exists 8.
    uint8_t state = graphGetValueState(attribute);
    if ((state & 0x7) != 0 || (state & 0x8) == 0) return NULL;
    return graphGetValue(attribute, 0, type).value;
}

bool LIAGAttributeTypesAreAvailable(void) {
    resolve();
    return graphGetAttributeInfo != NULL;
}

bool LIAGGraphGetAttributeTypes(uint32_t attribute, const void **ruleType, const void **valueType) {
    resolve();
    *ruleType = NULL;
    *valueType = NULL;
    // 2 is AGAttributeNil; the low two bits tell a direct attribute (0) from an offset or indirect one.
    if (!graphGetAttributeInfo || attribute == 0 || attribute == 2 || (attribute & 0x3) != 0) return false;
    LIAttributeInfo info = graphGetAttributeInfo(attribute);
    if (!info.type) return false;
    *ruleType = info.type[0];
    *valueType = info.type[1];
    return *ruleType != NULL;
}

uint32_t LIAGGraphGetIndirectAttribute(uint32_t attribute) {
    resolve();
    if (!graphGetIndirectAttribute) return attribute;
    // 2 is AGAttributeNil. An indirect attribute can read from another one: follow a few steps.
    for (int i = 0; i < 8 && attribute != 0 && attribute != 2; i++) {
        uint32_t source = graphGetIndirectAttribute(attribute);
        if (source == attribute || source == 0 || source == 2) break;
        attribute = source;
    }
    return attribute;
}

bool LIAGTreeElementGetGeometry(LIAGTreeElement element, uint32_t *position, const void **positionType,
                                uint32_t *size, const void **sizeType) {
    resolve();
    *position = 0; *size = 0; *positionType = NULL; *sizeType = NULL;
    if (!makeValueIterator || !nextValue || !treeValueKey || !treeValueValue || !treeValueType) return false;
    LIValueIterator it = makeValueIterator(element);
    for (int i = 0; i < 64; i++) {
        const void *value = nextValue(&it);
        if (!value) break;
        const char *name = treeValueKey(value);
        if (!name) continue;
        if (strcmp(name, "position") == 0) { *position = treeValueValue(value); *positionType = treeValueType(value); }
        else if (strcmp(name, "size") == 0) { *size = treeValueValue(value); *sizeType = treeValueType(value); }
    }
    return *position != 0 && *size != 0 && *positionType && *sizeType;
}

uint32_t LIAGTreeElementGetValueNamed(LIAGTreeElement element, const char *key, const void **type) {
    resolve();
    *type = NULL;
    if (!makeValueIterator || !nextValue || !treeValueKey || !treeValueValue || !treeValueType) return 0;
    LIValueIterator it = makeValueIterator(element);
    for (int i = 0; i < 64; i++) {
        const void *value = nextValue(&it);
        if (!value) break;
        const char *name = treeValueKey(value);
        if (name && strcmp(name, key) == 0) {
            *type = treeValueType(value);
            return treeValueValue(value);
        }
    }
    return 0;
}

int LIAGTreeElementGetNodes(LIAGTreeElement element, uint32_t *out, int max) {
    if (!LIAGProfilingIsAvailable()) return 0;
    LINodeIterator it = makeNodeIterator(element);
    int n = 0;
    while (n < max) {
        uint32_t node = nextNode(&it);
        // AGAttributeNil is 2; 0 is never a node either.
        if (node == 2 || node == 0) break;
        out[n++] = node;
    }
    return n;
}

// MARK: - Xcode previews

#include <stdlib.h>
#include <TargetConditionals.h>

#if TARGET_OS_IOS
// Previews and Xcode's RunCodeSnippet run the code in a process where nothing may call
// `LayoutInspector.bootstrap()` early enough: previews of a package or a framework are hosted by Xcode's own
// app, which has no `App.init` of yours. This runs when the binary is loaded – before SwiftUI creates its
// first view graph – and only in those processes. "27" is `LayoutInspector.debugProperties`
// (type | value | position | size). An existing value is kept.
__attribute__((constructor)) static void LIBootstrapForXcodePreviews(void) {
    const char *previews = getenv("XCODE_RUNNING_FOR_PREVIEWS");
    if (previews && strcmp(previews, "1") == 0) setenv("SWIFTUI_VIEW_DEBUG", "27", 0);
}
#endif

#endif // LAYOUT_INSPECTOR_DISABLED
