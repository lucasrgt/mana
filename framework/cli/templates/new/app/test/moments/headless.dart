import 'package:__name___app/app.dart';
import 'package:live_ui/headless.dart';

/// The app as a headless suite worker runs it, one Moment after another.
void headlessMain(int worker) =>
    runHeadlessMoments(worker: worker, reset: () {}, start: startApp);
