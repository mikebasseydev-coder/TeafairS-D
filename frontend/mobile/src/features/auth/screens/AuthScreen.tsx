import { useState } from 'react';
import { Text, View } from 'react-native';
import { useAuthStore } from '@teafair/core';
import { Button, InputField } from '../../../components';

export function AuthScreen() {
  const state = useAuthStore();
  const [email, setEmail] = useState('');

  return (
    <View className="flex-1 justify-center p-4">
      <Text>Auth</Text>
      <Text>{JSON.stringify(state)}</Text>
      <InputField label="Email" value={email} onChangeText={setEmail} />
      <Button label="Continue" onPress={() => {}} />
    </View>
  );
}
