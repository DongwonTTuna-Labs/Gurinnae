export type ProjectionPrimitive = string | number | boolean;

export type ProjectionListValue = {
  kind: "list";
  items: readonly ProjectionValue[];
  omittedCount: number;
};

export type ProjectionRecordEntry = {
  name: string;
  label: string;
  value: ProjectionValue;
};

export type ProjectionRecordValue = {
  kind: "record";
  entries: readonly ProjectionRecordEntry[];
  omittedCount: number;
};

/** Browser-safe scalar or bounded structured projection value. */
export type ProjectionValue =
  | ProjectionPrimitive
  | ProjectionListValue
  | ProjectionRecordValue;

export type PresentedScalarValue = {
  kind: "scalar";
  valueKind:
    | "boolean"
    | "date"
    | "duration"
    | "enum"
    | "money"
    | "number"
    | "text"
    | "uuid";
  text: string;
  secondary?: string;
  title?: string;
  copyText?: string;
};

export type PresentedListValue = {
  kind: "list";
  items: readonly PresentedProjectionValue[];
  omittedCount: number;
};

export type PresentedRecordValue = {
  kind: "record";
  entries: readonly {
    name: string;
    label: string;
    value: PresentedProjectionValue;
  }[];
  omittedCount: number;
};

export type PresentedProjectionValue =
  | PresentedScalarValue
  | PresentedListValue
  | PresentedRecordValue;

export type ProjectionPresentationOptions = {
  /** Explicit comparison clock. Omit it to keep SSR output time-invariant. */
  relativeTo?: Date;
};
