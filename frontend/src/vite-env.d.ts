declare module "lucide-react" {
  import type { ComponentType, SVGProps } from "react";

  export type IconProps = SVGProps<SVGSVGElement> & {
    size?: number | string;
  };

  export const RefreshCw: ComponentType<IconProps>;
  export const Search: ComponentType<IconProps>;
  export const Star: ComponentType<IconProps>;
  export const Trash2: ComponentType<IconProps>;
  export const Clock: ComponentType<IconProps>;
  export const Database: ComponentType<IconProps>;
  export const Plus: ComponentType<IconProps>;
}
