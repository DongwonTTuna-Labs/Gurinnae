import type { ProjectionField } from "./screen-projection";
import type { Cas010Metric } from "./view-models/cas-010";
import type { Cas011GraphRow } from "./view-models/cas-011";

export type AnalysisProjection = {
  visualizations: readonly Cas010Metric[];
  provenanceRows: readonly Cas011GraphRow[];
};

/** Result of a closed, screen-specific browser projection mapper. */
export type SpecializedProjection = {
  fields: ProjectionField[];
  blocked: boolean;
  analysis?: AnalysisProjection;
};
