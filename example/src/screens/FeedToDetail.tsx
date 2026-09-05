import { FlashList } from '@shopify/flash-list'
import { useState } from 'react'
import {
  Modal,
  Pressable,
  SafeAreaView,
  StyleSheet,
  Text,
  View,
} from 'react-native'
import { VideoView } from 'react-native-jet-video'

const VIDEOS = [
  'https://storage.googleapis.com/exoplayer-test-media-0/BigBuckBunny_320x180.mp4',
  'https://media.w3.org/2010/05/sintel/trailer.mp4',
  'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8',
] as const

interface Item {
  id: number
  uri: string
}

const ITEMS: Item[] = Array.from({ length: 60 }, (_, index) => ({
  id: index,
  uri: VIDEOS[index % VIDEOS.length] as string,
}))

/**
 * Feed → post detail: the detail screen shows the same video (same
 * `playerKey`, here the default source uri) and must continue from the same
 * frame without reloading; popping back must do the same in reverse.
 */
export function FeedToDetail() {
  const [open, setOpen] = useState<Item | null>(null)

  return (
    <View style={styles.container}>
      <FlashList
        data={ITEMS}
        keyExtractor={(item) => String(item.id)}
        renderItem={({ item }) => (
          <Cell item={item} onPress={() => setOpen(item)} />
        )}
      />
      <Modal
        animationType="slide"
        onRequestClose={() => setOpen(null)}
        presentationStyle="fullScreen"
        visible={open !== null}
      >
        {open ? <Detail item={open} onClose={() => setOpen(null)} /> : null}
      </Modal>
    </View>
  )
}

function Cell({ item, onPress }: { item: Item; onPress: () => void }) {
  const [time, setTime] = useState(0)
  const [status, setStatus] = useState('idle')

  return (
    <Pressable onPress={onPress} style={styles.cell} testID={`cell-${item.id}`}>
      <VideoView
        source={item.uri}
        autoplay="whenVisible"
        muted
        loop
        style={styles.video}
        onPlaybackStateChange={(event) => setStatus(event.status)}
        onProgress={(event) => setTime(event.currentTime)}
      />
      <Text style={styles.meta} testID={`cell-${item.id}-meta`}>
        #{item.id} · {status} · t={time.toFixed(1)}
      </Text>
    </Pressable>
  )
}

function Detail({ item, onClose }: { item: Item; onClose: () => void }) {
  const [time, setTime] = useState(0)
  const [status, setStatus] = useState('idle')

  return (
    <SafeAreaView style={styles.container}>
      <Pressable onPress={onClose} style={styles.back} testID="detail-back">
        <Text style={styles.backText}>‹ Back to feed</Text>
      </Pressable>
      <VideoView
        source={item.uri}
        autoplay="whenVisible"
        muted
        loop
        style={styles.video}
        onPlaybackStateChange={(event) => setStatus(event.status)}
        onProgress={(event) => setTime(event.currentTime)}
      />
      <Text style={styles.meta} testID="detail-meta">
        detail #{item.id} · {status} · t={time.toFixed(1)}
      </Text>
    </SafeAreaView>
  )
}

const styles = StyleSheet.create({
  container: {
    backgroundColor: '#000',
    flex: 1,
  },
  cell: {
    marginBottom: 24,
  },
  video: {
    aspectRatio: 16 / 9,
    backgroundColor: '#000',
    width: '100%',
  },
  meta: {
    color: '#9f9',
    fontFamily: 'Menlo',
    fontSize: 12,
    padding: 8,
  },
  back: {
    padding: 12,
  },
  backText: {
    color: '#5e9eff',
    fontSize: 16,
  },
})
