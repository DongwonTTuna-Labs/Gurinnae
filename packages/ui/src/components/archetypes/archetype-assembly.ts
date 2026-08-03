import type {
  ScreenRuntime,
  ScreenViewModel,
  TypedScreenViewModel,
} from "../../index";
import type { ScreenProjection } from "../../screen-projection";

export type SectionLayoutVariant = "standard" | "workspace" | "form";

export type ArchetypeAssemblyProps = {
  screen: ScreenViewModel;
  runtime: ScreenRuntime;
  contract: TypedScreenViewModel;
  projection: ScreenProjection;
  skipStatus?: boolean;
  variant?: SectionLayoutVariant;
};
