import '../../models/show.dart';
import 'debrid_client.dart';

/// Supported debrid service types
enum DebridType {
  realDebrid('Real-Debrid', 'real-debrid.com/apitoken'),
  allDebrid('AllDebrid', 'alldebrid.com/apikeys'),
  premiumize('Premiumize', 'premiumize.me/account'),
  debridLink('Debrid-Link', 'debrid-link.com/webapp/apikey'),
  offcloud('Offcloud', 'offcloud.com/account/apikeys'),
  putio('put.io', 'app.put.io/settings/account');

  final String displayName;
  final String tokenUrl;
  const DebridType(this.displayName, this.tokenUrl);
}

/// Abstract interface for all debrid services
abstract class DebridService {
  String get serviceName;

  /// Check if torrent hashes are instantly available (cached)
  Future<Map<String, List<DebridFile>>> checkInstantAvailability(
    List<String> hashes,
  );

  /// Unrestrict/unlock a link to get a direct stream URL
  Future<ResolvedStream> unrestrictLink(String link);

  /// Full flow: magnet → stream URL
  Future<ResolvedStream?> resolveFromMagnet(
    String magnetLink, {
    void Function(String status, int progress)? onProgress,
  });

  /// Verify the API token is valid
  Future<bool> verifyToken();
}

/// Factory to create the right debrid client for a given type
DebridService createDebridService(DebridType type, String apiToken) {
  switch (type) {
    case DebridType.realDebrid:
      return RealDebridService(apiToken: apiToken);
    case DebridType.allDebrid:
      return AllDebridService(apiToken: apiToken);
    case DebridType.premiumize:
      return PremiumizeService(apiToken: apiToken);
    case DebridType.debridLink:
      return DebridLinkService(apiToken: apiToken);
    case DebridType.offcloud:
      return OffcloudService(apiToken: apiToken);
    case DebridType.putio:
      return PutioService(apiToken: apiToken);
  }
}
