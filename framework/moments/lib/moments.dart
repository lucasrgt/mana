/// The Moments runner. A project's `moments/adapters.dart` program imports this
/// library, registers its [ProjectAdapters] and calls [runCli].
library;

export 'src/adapter.dart' show Adapter;
export 'src/android_actor.dart' show AndroidActor, AndroidBinary, nativeMomentRoute, recoverAndroidActor;
export 'src/artifact_cache.dart' show ArtifactCache;
export 'src/browser.dart'
    show
        BrowserBoundary,
        BrowserHost,
        BrowserProvider,
        actorBrowserLocation,
        allocateBrowserBoundary,
        browserSocketProvider,
        recoverBrowserBoundary;
export 'src/canonical.dart' show hashBytes, hashText;
export 'src/check.dart' show checkMoment;
export 'src/cli.dart' show runCli;
export 'src/composition.dart' show CompositionConnection, Interruption, compileComposition, executeComposition;
export 'src/dart_sources.dart' show DartSources;
export 'src/errors.dart' show MomentsError;
export 'src/flutter_actor.dart'
    show
        ActorBackend,
        ActorBridgeOptions,
        ActorFrontend,
        ActorHandle,
        ActorLaunch,
        FlutterActorRuntime,
        FlutterActorServices,
        LocalActorRecovery,
        RuntimeRecovery;
export 'src/flutter_target.dart' show flutterTarget;
export 'src/inspect.dart' show Development, Renewal;
export 'src/instance_state.dart' show inspectInstance;
export 'src/journey.dart' show JourneyError, Request;
export 'src/layers.dart' show FlutterActorLayer, Layer, LayerDriver, LayerHandle, LayerOptions, PrivateJsonLayer;
export 'src/managed.dart'
    show
        CompositionContext,
        CompositionProfile,
        MaterializationContext,
        MaterializationEngine,
        MaterializationProfile,
        PreparationAdapter,
        ProjectAdapters,
        recoverMaterialization,
        registerPreparation,
        validatePreparationResources,
        validateRecoveryResources;
export 'src/manifest.dart' show Manifest, readManifest;
export 'src/materializer.dart' show Materializer, MaterializerRuntime, Snapshot, TransitionRecipe, World;
export 'src/owned_process.dart' show OwnedProcess, allocateOwnedProcess, inspectOwnedProcess, recoverOwnedProcess;
export 'src/postgres_layer.dart' show PostgresDocker, PostgresLayer, postgresDocker;
export 'src/preview_host.dart' show PreviewHost;
