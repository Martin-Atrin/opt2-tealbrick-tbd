export interface ControlPlaneProfile {
  id: string;
  name: string;
  issuer: string;
  builtIn: boolean;
}

export interface ControlPlaneState {
  activeId: string;
  profiles: ControlPlaneProfile[];
}
