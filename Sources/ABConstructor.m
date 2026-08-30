#import "ABStoreKitHooks.h"
#import "ABThirdPartyAdHooks.h"

__attribute__((constructor))
static void ABEntryPoint(void) {
    ABInstallStoreKitHooks();
    ABInstallThirdPartyAdHooks();
}
