#include "LIAttributeGraph.h"
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
