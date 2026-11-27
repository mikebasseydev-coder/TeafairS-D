// The fixed icon of each tone (FIGMA.md §3): status is never colour alone.
import Svg, { Circle, Path, Rect } from "react-native-svg";
import { toneIcon, type SemanticTone } from "@/shared/tokens";
import { useTheme } from "./theme";

export function ToneIcon({ tone, size = 16 }: { tone: SemanticTone; size?: number }) {
  const c = useTheme().tones[tone].mark;
  const sw = 2;
  const common = { fill: "none", stroke: c, strokeWidth: sw, strokeLinecap: "round", strokeLinejoin: "round" } as const;
  let body;
  switch (toneIcon[tone]) {
    case "dot":
      body = <Circle cx={12} cy={12} r={5} fill={c} />;
      break;
    case "leaf":
      body = (
        <>
          <Path d="M5 19c0-8 5-14 15-14 0 10-6 15-14 15" {...common} />
          <Path d="M5 19 13 11" {...common} />
        </>
      );
      break;
    case "check":
      body = (
        <>
          <Circle cx={12} cy={12} r={9} {...common} />
          <Path d="m8 12.5 2.5 2.5L16 9.5" {...common} />
        </>
      );
      break;
    case "triangle":
      body = (
        <>
          <Path d="M12 3.5 21.5 20h-19z" {...common} />
          <Path d="M12 10v4" {...common} />
          <Rect x={11} y={16.2} width={2} height={2} rx={1} fill={c} />
        </>
      );
      break;
    case "octagon":
      body = (
        <>
          <Path d="M8.3 3h7.4L21 8.3v7.4L15.7 21H8.3L3 15.7V8.3z" {...common} />
          <Path d="M12 7.5v5.5" {...common} />
          <Rect x={11} y={15.2} width={2} height={2} rx={1} fill={c} />
        </>
      );
      break;
    case "info":
      body = (
        <>
          <Circle cx={12} cy={12} r={9} {...common} />
          <Path d="M12 11v6" {...common} />
          <Rect x={11} y={7} width={2} height={2} rx={1} fill={c} />
        </>
      );
      break;
    case "clock":
      body = (
        <>
          <Circle cx={12} cy={12} r={9} {...common} />
          <Path d="M12 7v5l3 2" {...common} />
        </>
      );
      break;
  }
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" accessible={false} testID={`tone-icon-${tone}`}>
      {body}
    </Svg>
  );
}
