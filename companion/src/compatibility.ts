import type { RconSettings } from "./config.js";
import { PROTOCOL_VERSION, assertProtocolCompatibility } from "./protocol/contract.js";

export const EXPECTED_RCON_HOST = "127.0.0.1";
export const EXPECTED_RCON_PORT = 19015;

export interface PingIdentity {
  protocol_version?: number;
  mod_version?: string;
}

export function connectionCompatibility(settings: RconSettings, ping?: PingIdentity, appVersion?: string) {
  return {
    endpoint: settings.host === EXPECTED_RCON_HOST && settings.port === EXPECTED_RCON_PORT,
    protocol: ping === undefined ? undefined : ping.protocol_version === PROTOCOL_VERSION,
    mod: ping === undefined || appVersion === undefined ? undefined : ping.mod_version === appVersion,
  };
}

export function assertConnectionCompatibility(settings: RconSettings, ping?: PingIdentity, appVersion?: string): void {
  const valid = connectionCompatibility(settings, ping, appVersion);
  if (!valid.endpoint) {
    throw new Error(`RCON must use ${EXPECTED_RCON_HOST}:${EXPECTED_RCON_PORT}; run setup again`);
  }
  if (ping) {
    assertProtocolCompatibility(ping);
    if (!valid.mod) {
      throw new Error(`mod version mismatch: mod v${ping.mod_version ?? "unknown"}, app v${appVersion ?? "unknown"} — reinstall the matching mod and restart Factorio`);
    }
  }
}
