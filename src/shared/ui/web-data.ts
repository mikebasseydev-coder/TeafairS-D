// `dataSet` becomes data-* attributes on react-native-web (the Playwright
// target) and is ignored on native. React Native's types do not declare it.
// eslint-disable-next-line @typescript-eslint/no-empty-object-type
export function webData(data: Record<string, string>): {} {
  return { dataSet: data };
}
