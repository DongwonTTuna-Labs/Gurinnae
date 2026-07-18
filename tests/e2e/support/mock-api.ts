import { handleMockRequest } from "./mock-api-routes";
import { port } from "./mock-api-state";

Bun.serve({ hostname: "127.0.0.1", port, fetch: handleMockRequest });
