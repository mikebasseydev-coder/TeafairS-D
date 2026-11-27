// The shared layer's public surface. `shared` imports no feature (Spec B §3).
export * from "./tokens";
export * from "./ui";
export { rpc, type RpcArgs, type RpcReturn } from "./network/rpc";
export { gateway } from "./network/gateway";
export { APP_RPCS, type AppRpcName } from "./network/rpc-map";
export { GATEWAY_NAMES, gatewaySchemas, type GatewayName, type GatewayBody } from "./network/gateways";
export { fromGateway, fromPostgrest, networkError, type AppError, type Result } from "./network/errors";
export { queueTone, queueLabel, type QueueStatus } from "./network/queue/queue-tone";
export { registerReset, runResets, type ResetScope } from "./storage/reset-registry";
export { log, setLogSink } from "./observability/log";
