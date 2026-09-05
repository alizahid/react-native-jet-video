import { NavigationContainer } from '@react-navigation/native'
import {
  createNativeStackNavigator,
  type NativeStackScreenProps,
} from '@react-navigation/native-stack'
import type { ComponentType } from 'react'
import { Pressable, StyleSheet, Text, View } from 'react-native'

import { BasicPlayback } from './screens/BasicPlayback'
import { Cache } from './screens/Cache'
import { Feed } from './screens/Feed'
import { FeedToDetail } from './screens/FeedToDetail'
import { Fullscreen } from './screens/Fullscreen'
import { PictureInPicture } from './screens/PictureInPicture'
import { RefMethods } from './screens/RefMethods'
import { Stacked } from './screens/Stacked'
import { SwipeActions } from './screens/SwipeActions'

const SCREENS = {
  BasicPlayback: BasicPlayback,
  RefMethods: RefMethods,
  Feed: Feed,
  FeedToDetail: FeedToDetail,
  Stacked: Stacked,
  SwipeActions: SwipeActions,
  Fullscreen: Fullscreen,
  PictureInPicture: PictureInPicture,
  Cache: Cache,
} as const

type ScreenName = keyof typeof SCREENS

export type RootStackParamList = {
  Home: undefined
} & {
  [Name in ScreenName]: { depth?: number } | undefined
}

const Stack = createNativeStackNavigator<RootStackParamList>()

function Home({
  navigation,
}: NativeStackScreenProps<RootStackParamList, 'Home'>) {
  return (
    <View style={styles.container}>
      <View style={styles.menu}>
        {(Object.keys(SCREENS) as ScreenName[]).map((name) => (
          <Pressable
            key={name}
            onPress={() => navigation.push(name)}
            style={styles.item}
            testID={`screen-${name}`}
          >
            <Text style={styles.itemText}>{name}</Text>
          </Pressable>
        ))}
      </View>
    </View>
  )
}

function App() {
  return (
    <NavigationContainer>
      <Stack.Navigator
        screenOptions={{
          contentStyle: styles.container,
          headerStyle: { backgroundColor: '#000' },
          headerTintColor: '#5e9eff',
          headerTitleStyle: { color: '#fff' },
        }}
      >
        <Stack.Screen
          component={Home}
          name="Home"
          options={{ title: 'react-native-jet-video' }}
        />
        {(Object.keys(SCREENS) as ScreenName[]).map((name) => (
          <Stack.Screen
            // biome-ignore lint/suspicious/noExplicitAny: screens take differing props
            component={SCREENS[name] as ComponentType<any>}
            key={name}
            name={name}
          />
        ))}
      </Stack.Navigator>
    </NavigationContainer>
  )
}

const styles = StyleSheet.create({
  container: {
    backgroundColor: '#000',
    flex: 1,
  },
  menu: {
    gap: 1,
  },
  item: {
    backgroundColor: '#1c1c1e',
    padding: 16,
  },
  itemText: {
    color: '#fff',
    fontSize: 16,
  },
})

export default App
