import { useState } from 'react'
import { Modal, Pressable, SafeAreaView, StyleSheet, Text } from 'react-native'
import { Feed } from './Feed'

/**
 * Simulates a deep navigation stack of video feeds (Acorn-style: feed →
 * community → user → community → …). Each pushed screen is a fullScreen
 * Modal, which detaches the covered screen from the window exactly like
 * react-native-screens does — so covered feeds should hibernate their
 * players, and popping back should restore position seamlessly.
 */
function StackLevel({ depth }: { depth: number }) {
  const [pushed, setPushed] = useState(false)

  return (
    <SafeAreaView style={styles.container}>
      <Pressable
        onPress={() => setPushed(true)}
        style={styles.push}
        testID={`push-${depth}`}
      >
        <Text style={styles.pushText}>Depth {depth} · push another feed ›</Text>
      </Pressable>
      <Feed />
      <Modal
        animationType="slide"
        onRequestClose={() => setPushed(false)}
        presentationStyle="fullScreen"
        visible={pushed}
      >
        <SafeAreaView style={styles.container}>
          <Pressable
            onPress={() => setPushed(false)}
            style={styles.push}
            testID={`pop-${depth + 1}`}
          >
            <Text style={styles.pushText}>‹ Pop to depth {depth}</Text>
          </Pressable>
          <StackLevel depth={depth + 1} />
        </SafeAreaView>
      </Modal>
    </SafeAreaView>
  )
}

export function Stacked() {
  return <StackLevel depth={1} />
}

const styles = StyleSheet.create({
  container: {
    backgroundColor: '#000',
    flex: 1,
  },
  push: {
    backgroundColor: '#1c1c1e',
    padding: 12,
  },
  pushText: {
    color: '#5e9eff',
    fontSize: 15,
    fontWeight: '600',
  },
})
