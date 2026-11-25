// Runtime ports must have their own approved sources before composition can
// consume any of these switches.
const t32bHealthReplayApproved = bool.fromEnvironment(
  'T32B_HEALTH_REPLAY_APPROVED',
  defaultValue: false,
);
const t32bVoiceReplayApproved = bool.fromEnvironment(
  'T32B_VOICE_REPLAY_APPROVED',
  defaultValue: false,
);
const t32bLiveFramesApproved = bool.fromEnvironment(
  'T32B_LIVE_FRAMES_APPROVED',
  defaultValue: false,
);
