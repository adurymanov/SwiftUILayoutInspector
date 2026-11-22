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
typedef LIAGTreeElement (*NextChild2Fn)(LIChildIterator *, bool);
static NextChild2Fn nextChild2;
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
    nextChild2 = (NextChild2Fn)dlsym(h, "AGTreeElementGetNextChild2");
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
    if (!LIAGIsAvailable()) return 0;
    LIChildIterator it;
    memset(&it, 0, sizeof(it));
    it = makeChildIterator(element);
    int n = 0;
    LIAGTreeElement child;
    while (n < max && (child = nextChild(&it)) != NULL) {
        out[n++] = child;
    }
    return n;
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

// MARK: - Child walk

#include <stdlib.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#define LI_CODE(f) ((const uint32_t *)ptrauth_strip((void *)(f), ptrauth_key_function_pointer))
#else
#define LI_CODE(f) ((const uint32_t *)(void *)(f))
#endif

// The instructions of the functions the walk relies on, PC-relative parts (adrp and the add after it, bl, b) left
// out, hashed (FNV-1a), read from AttributeGraph with lldb: AGTreeElementGetNextChild2, AGTreeElementGetValue,
// AGSubgraphGetTreeRoot, AGTreeElementMakeNodeIterator, AGTreeElementGetNextNode, AGGraphGetIndirectAttribute, then
// the two they call, AG::Subgraph::tree_subgraph_child and tree_node_at_index (read only once the callers matched).
// Any other code gets no walk. On 26.5 tree_subgraph_child differs from 27.0 only in registers and in the helper that
// resolves an indirect root value.
enum { hashedFunctions = 8, directFunctions = 6 };
static const uint64_t knownHashes[][hashedFunctions] = {
    // iOS 27.0 simulator
    {0x4d12230787c996a7ULL, 0x3596a9408f35b3c5ULL, 0x2adc5a68b6f4c707ULL, 0x652e5fd0336f2004ULL, 0x8c7fd533dd169a5bULL,
     0x9a65809fc6a768c7ULL, 0x5cc89d869fbb8a88ULL, 0xe78dd368c24021f4ULL},
    // iOS 26.5 simulator
    {0x4d12230787c996a7ULL, 0x3596a9408f35b3c5ULL, 0x2adc5a68b6f4c707ULL, 0x652e5fd0336f2004ULL, 0x8c7fd533dd169a5bULL,
     0x85be97c35e6fca65ULL, 0x8ab6470c02de79aeULL, 0xe78dd368c24021f4ULL},
};
static const int hashedWords[hashedFunctions] = {33, 6, 7, 2, 24, 10, 170, 50};
// Where the callers call them: word 27 of AGTreeElementGetNextChild2, word 11 of AGTreeElementGetNextNode.
static const int callSites[2][2] = {{0, 27}, {4, 11}};
static uint64_t codeHashes[hashedFunctions];
static int walkState; // 0 unchecked, 1 available, -1 not
// AG::data::_shared_table_bytes: the base all tree elements and nodes are offsets from.
static const uint8_t *const *sharedTable;

static uint64_t maskedHash(const uint32_t *code, int words) {
    uint64_t h = 0xcbf29ce484222325ULL;
    bool afterAdrp = false;
    for (int i = 0; i < words; i++) {
        uint32_t w = code[i], m = w;
        if ((w & 0x9F000000) == 0x90000000) m = 0x90000000;
        else if ((w & 0xFC000000) == 0x94000000) m = 0x94000000;
        else if ((w & 0xFC000000) == 0x14000000) m = 0x14000000;
        else if (afterAdrp && (w & 0xFFC00000) == 0x91000000) m = w & 0xFFC003FF;
        afterAdrp = (w & 0x9F000000) == 0x90000000;
        h = (h ^ m) * 0x100000001b3ULL;
    }
    return h;
}

static const uint32_t *branchTarget(const uint32_t *at) {
    uint32_t w = *at;
    if ((w & 0xFC000000) != 0x94000000) return NULL;
    int32_t imm = (int32_t)(w << 6) >> 6;
    return at + imm;
}

/// `adrp xN, page; add xN, xN, #off` at `at`: the address they build.
static const void *adrpAdd(const uint32_t *at) {
    uint32_t adrp = at[0], add = at[1];
    if ((adrp & 0x9F000000) != 0x90000000 || (add & 0xFFC00000) != 0x91000000) return NULL;
    int64_t immhi = (int64_t)((int32_t)(adrp << 8) >> 13), immlo = (adrp >> 29) & 3;
    uintptr_t page = ((uintptr_t)at & ~(uintptr_t)0xFFF) + (uintptr_t)(((immhi << 2) | immlo) << 12);
    return (const void *)(page + ((add >> 10) & 0xFFF));
}

static bool walkIsAvailable(void) {
    if (walkState != 0) return walkState > 0;
    walkState = -1;
    if (!LIAGIsAvailable() || !nextChild2 || !makeNodeIterator || !nextNode || !graphGetIndirectAttribute) return false;
#if defined(__arm64__)
    const uint32_t *code[hashedFunctions] = {LI_CODE(nextChild2), LI_CODE(getValue), LI_CODE(getTreeRoot),
                                             LI_CODE(makeNodeIterator), LI_CODE(nextNode), LI_CODE(graphGetIndirectAttribute)};
    for (int i = 0; i < directFunctions; i++) codeHashes[i] = maskedHash(code[i], hashedWords[i]);
    size_t rows = sizeof(knownHashes) / sizeof(knownHashes[0]);
    for (size_t k = 0; k < rows; k++) {
        if (memcmp(knownHashes[k], codeHashes, sizeof(uint64_t) * directFunctions) != 0) continue;
        for (int c = 0; c < 2; c++) {
            const uint32_t *callee = branchTarget(code[callSites[c][0]] + callSites[c][1]);
            if (!callee) return false;
            code[directFunctions + c] = callee;
            codeHashes[directFunctions + c] = maskedHash(callee, hashedWords[directFunctions + c]);
        }
        break;
    }
    for (size_t k = 0; k < rows; k++) {
        if (memcmp(knownHashes[k], codeHashes, sizeof(codeHashes)) != 0) continue;
        sharedTable = (const uint8_t *const *)adrpAdd(LI_CODE(getValue));
        if (sharedTable) walkState = 1;
        break;
    }
#endif
    return walkState > 0;
}

bool LIAGChildWalkIsAvailable(void) { return walkIsAvailable(); }

void LIAGChildWalkCodeHashes(uint64_t *out) {
    walkIsAvailable();
    memcpy(out, codeHashes, sizeof(codeHashes));
}

struct LIAGChildWalk {
    const uint8_t *graph;
    uint32_t *values;
    size_t count;
    int searched;
};

static int compareU32(const void *a, const void *b) {
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return x < y ? -1 : x > y;
}

LIAGChildWalk *LIAGChildWalkCreate(const void *subgraph) {
    if (!walkIsAvailable()) return NULL;
    // Offsets as tree_subgraph_child reads them: AGSubgraphRef + 0x10 is the AG::Subgraph, + 0x28 its graph, whose
    // subgraphs are at + 0x128 (count at + 0x130); a subgraph's tree root is at + 0x60.
    const uint8_t *own = *(const uint8_t *const *)((const uint8_t *)subgraph + 0x10);
    if (!own) return NULL;
    const uint8_t *graph = *(const uint8_t *const *)(own + 0x28);
    if (!graph) return NULL;
    const uint8_t *const *subgraphs = *(const uint8_t *const *const *)(graph + 0x128);
    uint32_t total = *(const uint32_t *)(graph + 0x130);
    if (!subgraphs && total) return NULL;
    LIAGChildWalk *walk = calloc(1, sizeof(LIAGChildWalk));
    if (!walk) return NULL;
    walk->graph = graph;
    walk->values = malloc(sizeof(uint32_t) * (total ? total : 1));
    if (!walk->values) { free(walk); return NULL; }
    // The subgraphs AttributeGraph checks (not invalidated: byte + 0x68), indirect values followed to their source
    // as it resolves them: an element that owns none of these values can't have a subgraph hung under it.
    for (uint32_t i = 0; i < total; i++) {
        const uint8_t *s = subgraphs[i];
        if (!s || s[0x68] != 0) continue;
        uint32_t root = *(const uint32_t *)(s + 0x60);
        if (root == 0) continue;
        uint32_t value = getValue((LIAGTreeElement)(uintptr_t)root);
        for (int hop = 0; hop < 64 && (value & 3) == 1; hop++) value = graphGetIndirectAttribute(value);
        if (value < 4 || (value & 3) != 0) continue;
        walk->values[walk->count++] = value;
    }
    qsort(walk->values, walk->count, sizeof(uint32_t), compareU32);
    return walk;
}

/// AttributeGraph would find a subgraph hung under `element`: it owns a node some subgraph's root holds, or it is in
/// another graph than the one the values were read from.
static bool mayHaveSubgraphs(LIAGChildWalk *walk, LIAGTreeElement element) {
    uint32_t e = (uint32_t)(uintptr_t)element;
    const uint8_t *page = *sharedTable + (e & 0xFFFFFE00);
    const uint8_t *owner = *(const uint8_t *const *)page;
    if (!owner || *(const uint8_t *const *)(owner + 0x28) != walk->graph) return true;
    if (walk->count == 0) return false;
    LINodeIterator it = makeNodeIterator(element);
    for (int i = 0; i < 100000; i++) {
        uint32_t node = nextNode(&it);
        if (node == 2 || node == 0) return false;
        if (bsearch(&node, walk->values, walk->count, sizeof(uint32_t), compareU32)) return true;
    }
    return true;
}

int LIAGChildWalkGetChildren(LIAGChildWalk *walk, LIAGTreeElement element, LIAGTreeElement *out, int max) {
    bool search = mayHaveSubgraphs(walk, element);
    if (search) walk->searched++;
    LIChildIterator it;
    memset(&it, 0, sizeof(it));
    it = makeChildIterator(element);
    int n = 0;
    LIAGTreeElement child;
    while (n < max && (child = nextChild2(&it, search)) != NULL) out[n++] = child;
    return n;
}

void LIAGChildWalkGetStats(LIAGChildWalk *walk, int *searched, int *roots) {
    *searched = walk->searched;
    *roots = (int)walk->count;
}

void LIAGChildWalkDestroy(LIAGChildWalk *walk) {
    free(walk->values);
    free(walk);
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
