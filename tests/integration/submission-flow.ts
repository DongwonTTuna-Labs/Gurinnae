import { runCorrectionFlow } from "./submission-flow-cases-a";
import { runResponseFlow } from "./submission-flow-cases-b";

await runCorrectionFlow();
await runResponseFlow();

console.log(
  "submission 34-operation/session/encryption/object-bytes/ClamAV integration: PASS",
);
