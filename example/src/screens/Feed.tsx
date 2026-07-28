import { FlashList } from '@shopify/flash-list'
import { useCallback, useRef, useState } from 'react'
import { Pressable, StyleSheet, Text, View } from 'react-native'
import {
  type PlaybackStatus,
  VideoView,
  type VideoViewRef,
} from 'react-native-nitro-video'

const VIDEOS = [
  'https://storage.googleapis.com/exoplayer-test-media-0/BigBuckBunny_320x180.mp4',
  'https://media.w3.org/2010/05/sintel/trailer.mp4',
  'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8',
] as const

interface FeedItem {
  id: number
  uri: string
}

const ITEMS: FeedItem[] = Array.from({ length: 200 }, (_, index) => ({
  id: index,
  uri: VIDEOS[index % VIDEOS.length] as string,
}))

function FeedCell({ item }: { item: FeedItem }) {
  const ref = useRef<VideoViewRef>(null)
  const [status, setStatus] = useState<PlaybackStatus>('idle')
  const [reason, setReason] = useState('')
  const [visible, setVisible] = useState(0)

  const togglePlayback = useCallback(() => {
    if (status === 'playing' || status === 'buffering') {
      ref.current?.pause()
    } else {
      ref.current?.play()
    }
  }, [status])

  return (
    <View style={styles.cell}>
      <Pressable onPress={togglePlayback}>
        <VideoView
          ref={ref}
          source={item.uri}
          autoplay="whenVisible"
          muted
          loop
          style={styles.video}
          onPlaybackStateChange={(event) => {
            setStatus(event.status)
            setReason(event.reason)
          }}
          onVisibilityChange={setVisible}
        />
      </Pressable>
      <View style={styles.meta}>
        <Text style={styles.metaText}>
          #{item.id} · {status}
          {reason ? ` (${reason})` : ''}
        </Text>
        <Text style={styles.metaText}>
          {Math.round(visible * 100)}% visible
        </Text>
      </View>
      {(status === 'playing' || status === 'buffering') && (
        <View style={styles.badge}>
          <Text style={styles.badgeText}>▶ PLAYING</Text>
        </View>
      )}
    </View>
  )
}

export function Feed() {
  return (
    <FlashList
      data={ITEMS}
      keyExtractor={(item) => String(item.id)}
      renderItem={({ item }) => <FeedCell item={item} />}
    />
  )
}

const styles = StyleSheet.create({
  cell: {
    marginBottom: 24,
  },
  video: {
    aspectRatio: 16 / 9,
    backgroundColor: '#000',
    width: '100%',
  },
  meta: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    paddingHorizontal: 12,
    paddingVertical: 8,
  },
  metaText: {
    color: '#9f9',
    fontFamily: 'Menlo',
    fontSize: 12,
  },
  badge: {
    backgroundColor: '#34c759',
    borderRadius: 6,
    left: 8,
    paddingHorizontal: 8,
    paddingVertical: 4,
    position: 'absolute',
    top: 8,
  },
  badgeText: {
    color: '#000',
    fontSize: 11,
    fontWeight: '700',
  },
})
