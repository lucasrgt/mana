import 'errors.dart';
import 'services.dart';

/// Whether `up` may prepare an interrupted startup preparation again on its
/// own: it stopped before anything was written (`startup`), or inside recipes
/// that all wrote only to databases of their own (`recipe` with `isolated`:
/// data-scoped recipes, a child cloned from its parent's snapshot) that were
/// never committed. The base, services and shared-database recipes write
/// where a second run would land on top of the first.
bool recoverablePreparation(Map<String, Object?>? instance, {required String initialMoment, Object? journey}) {
  final preparation = instance?['preparation'] as Map?;
  return preparation != null &&
      journey == null &&
      instance!['phase'] != 'seeding' &&
      preparation['moment'] == initialMoment &&
      (preparation['stage'] == 'startup' || (preparation['stage'] == 'recipe' && preparation['isolated'] == true));
}

/// [instance] with its recorded startup preparation moved to [stage]. Services
/// are prepared by the time recipes run, and nothing has run in the recipe
/// stage yet, so it starts isolated. Unchanged when no preparation is recorded
/// (an `open` after startup).
Map<String, Object?> preparationAt(Map<String, Object?> instance, String stage) {
  final preparation = instance['preparation'] as Map?;
  if (preparation == null) return instance;
  return {
    ...instance,
    'preparation': {
      ...preparation,
      'stage': stage,
      if (stage == 'recipe') ...{'servicesPrepared': true, 'isolated': true},
    },
  };
}

/// [instance] once [moment]'s recipe is about to run: the preparation stays
/// isolated only while every recipe it ran wrote to a database of its own.
Map<String, Object?> preparationTransition(Map<String, Object?> instance, String moment, bool isolated) {
  final preparation = instance['preparation'] as Map?;
  if (preparation?['stage'] != 'recipe') return instance;
  return {
    ...instance,
    'preparation': {...preparation!, 'transition': moment, 'isolated': preparation['isolated'] == true && isolated},
  };
}

/// An explicit retry may repeat only service setup whose owner declares it
/// idempotent. Base/recipe writes and interrupted journeys are never replayed.
/// Answers whether the interrupted preparation is [recoverablePreparation]
/// and `up` prepares it again without the flag.
bool validatePreparationRetry(
  Map<String, Object?>? instance, {
  required bool retryPreparation,
  required String initialMoment,
  required List<ServiceDefinition> services,
  Map<String, Object?>? journey,
}) {
  final preparation = instance?['preparation'] as Map?;
  if (preparation == null) {
    if (retryPreparation) throw const MomentsError('No interrupted service preparation to retry');
    return false;
  }
  if (!retryPreparation) {
    if (recoverablePreparation(instance, initialMoment: initialMoment, journey: journey)) return true;
    throw const MomentsError(
      'Previous startup preparation is incomplete; inspect local state. Idempotent services may use up --retry-preparation; reset --discard-data rebuilds the database.',
    );
  }
  if (journey != null ||
      preparation['stage'] != 'services' ||
      instance!['phase'] != 'ready' ||
      instance['launch'] == null ||
      preparation['moment'] != initialMoment) {
    throw const MomentsError('Only interrupted services on the same committed base and Moment can be retried');
  }
  if (services.isEmpty || services.any((s) => s.prepare != null && !s.prepareIdempotent)) {
    throw const MomentsError('Every service preparation must explicitly declare prepareIdempotent: true');
  }
  return false;
}
