import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/server/refresh_feature_cache.dart';

/// Class represents the Feature.
class Feature {
  late String featureName;
  late String status;
  late String description;
  bool isEnabled = true;
}

/// Class represents an entity for caching the feature.
class FeatureCacheEntry {
  late Feature feature;
  late int lastUpdatedEpoch;
}

/// The class responsible for maintaining the feature cache.
class FeatureCache {
  static final FeatureCache _singleton = FeatureCache._internal();

  FeatureCache._internal();

  factory FeatureCache.getInstance() {
    return _singleton;
  }

  final Map<String, Map<String, FeatureCacheEntry>> _featureCache = {};

  final cacheObservers = <RefreshFeatureCache>[];

  /// Returns [FeatureCacheEntry] for the given atSign and featureName
  FeatureCacheEntry getFeatureCacheEntry(String atSign, String featureName) {
    if (!_featureCache.containsKey(atSign) ||
        !_featureCache[atSign]!.containsKey(featureName)) {
      throw KeyNotFoundException('$atSign does not exist in feature cache');
    }
    return _featureCache[atSign]![featureName]!;
  }

  /// Clears the existing map and adds all the features to cache.
  void setFeatures(String atSign, Map<String, FeatureCacheEntry> feature) {
    if (_featureCache.containsKey(atSign)) {
      // If a feature is removed on the receiver's atSign, it has to removed from
      // the cache.
      // Since addAll appends to existing, clearing the map
      _featureCache[atSign]?.clear();
      // Adding all the features to the cache
      _featureCache[atSign]?.addAll(feature);
      return;
    }
    _featureCache.putIfAbsent(atSign, () => feature);
    // Notify atSign
    for (var observer in cacheObservers) {
      observer.notifyAtSign(atSign);
    }
  }
}
