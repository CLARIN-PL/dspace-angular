package net.handle.hdllib;

import java.net.InetAddress;
import java.nio.file.Files;
import java.nio.file.Path;

/** Verify a native HTTPS Handle response against this server's registered key. */
public final class HandleHttpsProbe {
    public static void main(String[] args) throws Exception {
        if (args.length != 3) {
            throw new IllegalArgumentException("Usage: HandleHttpsProbe HOST PORT HANDLE");
        }

        SiteInfo site = Encoder.decodeSiteInfoRecord(
                Files.readAllBytes(Path.of("/dspace/handle-server/siteinfo.bin")), 0);
        ResolutionRequest request = new ResolutionRequest(
                Util.encodeString(args[2]), null, null, null);
        request.serverPubKeyBytes = site.servers[0].publicKey;
        request.certify = true;

        AbstractResponse response = new HandleResolver().sendHttpsRequest(
                request, InetAddress.getByName(args[0]), Integer.parseInt(args[1]), null);
        if (response.responseCode != AbstractMessage.RC_SUCCESS) {
            throw new IllegalStateException("Handle responseCode=" + response.responseCode);
        }
        System.out.println(args[2] + ": certified native HTTPS responseCode=1");
    }
}
