// The Teafair emblem: the canonical transparent PNG (FIGMA.md §0, Spec B §4.6),
// never redrawn, recoloured, stretched or cropped. Clear space is one eighth of
// the seal's diameter on every side.
import { Image, View } from "react-native";

const SOURCE = require("../../../assets/branding/teafair-logo.png");

/** 24 dp only in the tab bar; 32 dp or more everywhere else. */
export type EmblemSize = 24 | 32 | 48 | 64 | 96;

export function Emblem({ size = 48, testID = "emblem" }: { size?: EmblemSize; testID?: string }) {
  const clear = size / 8;
  return (
    <View style={{ padding: clear }} testID={testID}>
      <Image
        source={SOURCE}
        accessibilityRole="image"
        accessibilityLabel="Teafair"
        resizeMode="contain"
        style={{ width: size, height: size }}
      />
    </View>
  );
}
