import { Text, TextInput, View } from 'react-native';
import type { TextInputProps } from 'react-native';

interface InputFieldProps extends TextInputProps {
  label: string;
}

export function InputField({ label, className, ...textInputProps }: InputFieldProps) {
  return (
    <View className="mb-4">
      <Text className="mb-1 text-sm font-medium text-gray-700">{label}</Text>
      <TextInput
        className={`rounded-md border border-gray-300 px-3 py-2 text-base ${className ?? ''}`}
        {...textInputProps}
      />
    </View>
  );
}
