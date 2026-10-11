import { nativeCall } from './platform';
export const toggleOrbWindow = () => nativeCall('listening');
export const closeOrbWindow = () => undefined;
export const moveOrbWindow = () => undefined;
export const voiceContext = () => null;
export const createLiveSession = () => { throw Error('Live voice agent transport is not connected. Use Listening for capture and transcription.'); };
export const voiceAsk = createLiveSession;
