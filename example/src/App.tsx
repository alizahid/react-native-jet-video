import { useState } from 'react'
import { Pressable, SafeAreaView, StyleSheet, Text, View } from 'react-native'
import { BasicPlayback } from './screens/BasicPlayback'
import { Cache } from './screens/Cache'
import { Feed } from './screens/Feed'
import { Fullscreen } from './screens/Fullscreen'
import { PictureInPicture } from './screens/PictureInPicture'
import { RefMethods } from './screens/RefMethods'
import { Stacked } from './screens/Stacked'

const SCREENS = {
  BasicPlayback: BasicPlayback,
  RefMethods: RefMethods,
  Feed: Feed,
  Stacked: Stacked,
  Fullscreen: Fullscreen,
  PictureInPicture: PictureInPicture,
  Cache: Cache,
} as const

type ScreenName = keyof typeof SCREENS

function App() {
  const [screen, setScreen] = useState<ScreenName | null>(null)

  if (screen) {
    const Screen = SCREENS[screen]

    return (
      <SafeAreaView style={styles.container}>
        <Pressable onPress={() => setScreen(null)} style={styles.back}>
          <Text style={styles.backText}>‹ Back</Text>
        </Pressable>
        <Screen />
      </SafeAreaView>
    )
  }

  return (
    <SafeAreaView style={styles.container}>
      <Text style={styles.title}>react-native-jet-video</Text>
      <View style={styles.menu}>
        {(Object.keys(SCREENS) as ScreenName[]).map((name) => (
          <Pressable
            key={name}
            onPress={() => setScreen(name)}
            style={styles.item}
            testID={`screen-${name}`}
          >
            <Text style={styles.itemText}>{name}</Text>
          </Pressable>
        ))}
      </View>
    </SafeAreaView>
  )
}

const styles = StyleSheet.create({
  container: {
    backgroundColor: '#000',
    flex: 1,
  },
  title: {
    color: '#fff',
    fontSize: 20,
    fontWeight: '700',
    padding: 16,
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
  back: {
    padding: 12,
  },
  backText: {
    color: '#5e9eff',
    fontSize: 16,
  },
})

export default App
