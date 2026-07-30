import { useState } from 'react'
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native'
import {
  type PlaybackStatus,
  VideoView,
  type VisibilityAxis,
} from 'react-native-jet-video'

const VIDEOS = [
  'https://storage.googleapis.com/exoplayer-test-media-0/BigBuckBunny_320x180.mp4',
  'https://media.w3.org/2010/05/sintel/trailer.mp4',
] as const

/**
 * Reproduces a feed where cells swipe horizontally for actions (upvote etc.).
 * With visibilityAxis="vertical" the video keeps playing while its card is
 * dragged sideways; with "both" it pauses once the visible area drops below
 * the election threshold.
 */
function SwipeCell({ uri, axis }: { uri: string; axis: VisibilityAxis }) {
  const [status, setStatus] = useState<PlaybackStatus>('idle')
  const [visible, setVisible] = useState(0)

  return (
    <View style={styles.cell}>
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        testID={`swipe-${axis}`}
      >
        <VideoView
          source={uri}
          autoplay="whenVisible"
          muted
          loop
          visibilityAxis={axis}
          style={styles.video}
          onPlaybackStateChange={(event) => setStatus(event.status)}
          onVisibilityChange={setVisible}
        />
        <View style={styles.action}>
          <Text style={styles.actionText}>⬆︎ upvote</Text>
        </View>
      </ScrollView>
      <View style={styles.meta}>
        <Text style={styles.metaText}>
          axis={axis} · {status}
        </Text>
        <Text style={styles.metaText}>
          {Math.round(visible * 100)}% visible
        </Text>
      </View>
    </View>
  )
}

export function SwipeActions() {
  const [axis, setAxis] = useState<VisibilityAxis>('vertical')

  return (
    <ScrollView>
      <Pressable
        onPress={() => setAxis(axis === 'vertical' ? 'both' : 'vertical')}
        style={styles.toggle}
        testID="toggle-axis"
      >
        <Text style={styles.toggleText}>
          visibilityAxis: {axis} (tap to toggle)
        </Text>
      </Pressable>
      {VIDEOS.map((uri) => (
        <SwipeCell key={uri} uri={uri} axis={axis} />
      ))}
      <View style={styles.spacer} />
    </ScrollView>
  )
}

const WIDTH = 360

const styles = StyleSheet.create({
  toggle: {
    backgroundColor: '#1c1c1e',
    margin: 12,
    padding: 12,
    borderRadius: 8,
  },
  toggleText: {
    color: '#5e9eff',
    fontFamily: 'Menlo',
    fontSize: 13,
  },
  cell: {
    marginBottom: 24,
  },
  video: {
    aspectRatio: 16 / 9,
    backgroundColor: '#000',
    width: WIDTH,
  },
  action: {
    alignItems: 'center',
    backgroundColor: '#34c759',
    justifyContent: 'center',
    width: 160,
  },
  actionText: {
    color: '#000',
    fontWeight: '700',
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
  spacer: {
    height: 600,
  },
})
