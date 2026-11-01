package dev.crumb.distributionconsumer;

import dev.crumb.core.CrumbUploadHttpResponse;
import dev.crumb.core.CrumbUploadTransport;

/** Exercises the published Java default method and older Kotlin compatibility bridge. */
final class TransportCompatibility {
    static void verify() {
        CrumbUploadTransport transport = request -> new CrumbUploadHttpResponse(204, new byte[0]);
        transport.cancel();
        CrumbUploadTransport.DefaultImpls.cancel(transport);
    }
}
