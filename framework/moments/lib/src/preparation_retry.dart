import 'errors.dart';
import 'services.dart';

/// An explicit retry may repeat only service setup whose owner declares it
/// idempotent. Base/recipe writes and interrupted journeys are never replayed.
void validatePreparationRetry(
  Map<String, Object?>? instance, {
  required bool retryPreparation,
  required String initialMoment,
  required List<ServiceDefinition> services,
  Map<String, Object?>? journey,
}) {
  final preparation = instance?['preparation'] as Map?;
  if (preparation == null) {
    if (retryPreparation) throw const MomentsError('No interrupted service preparation to retry');
    return;
  }
  if (!retryPreparation) {
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
}
