import 'package:flutter/foundation.dart';

// The Go bridge accepts only these markers, in journey order.
enum T26JourneyStage {
  login,
  assessment,
  plan,
  chat,
  score;

  void report() => debugPrintSynchronously('T26_STAGE $name');
}

// The Go bridge accepts these only while the journey is in assessment.
enum T26AssessmentPhase {
  load,
  answer,
  scene,
  submit,
  continueReady;

  void report() => debugPrintSynchronously('T26_ASSESSMENT $name');
}

enum T26ChatPhase {
  openPlan,
  planOpened,
  consent,
  chatInput,
  send,
  awaitReply,
  verifyReply,
  revealFinish;

  void report() => debugPrintSynchronously('T26_CHAT $name');
}

enum T26ScorePhase {
  finish,
  feedback,
  returnLobby,
  lobbyCurrent,
  lobbyBack,
  returnPlan,
  planCompletion,
  revealCompletion,
  readback,
  verified;

  void report() => debugPrintSynchronously('T26_SCORE $name');
}

void reportT26FinishBeforeScroll({required bool hittable}) =>
    debugPrintSynchronously('T26_FINISH ${hittable ? 'hit' : 'miss'}');
