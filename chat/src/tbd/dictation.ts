import { nativeCall } from './platform';
export const dictationAvailable = () => true;
export const transcribe = (samples: Float32Array) => nativeCall('transcribe', Array.from(samples));
