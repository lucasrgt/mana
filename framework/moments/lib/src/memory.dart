import 'platform.dart';

export 'platform.dart' show descendants;

/// What [root] and its descendants hold in memory (`HostPlatform.treeMemory`).
int treeMemory(int root) => host.treeMemory(root);
