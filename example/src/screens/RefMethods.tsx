import { useRef, useState } from 'react'
import { Pressable, StyleSheet, Text, View } from 'react-native'
import {
  type VideoPlaybackStateEvent,
  VideoView,
  type VideoViewRef,
} from 'react-native-jet-video'

const SOURCES = [
  'https://storage.googleapis.com/exoplayer-test-media-0/BigBuckBunny_320x180.mp4',
  'https://media.w3.org/2010/05/sintel/trailer.mp4',
] as const

const POSTER =
  'https://peach.blender.org/wp-content/uploads/title_anouncement.jpg'

export function RefMethods() {
  const ref = useRef<VideoViewRef>(null)
  const [sourceIndex, setSourceIndex] = useState(0)
  const [state, setState] = useState<VideoPlaybackStateEvent | null>(null)
  const [time, setTime] = useState('—')
  const [seekResult, setSeekResult] = useState('')

  const actions: [string, () => void][] = [
    ['play', () => ref.current?.play()],
    ['pause', () => ref.current?.pause()],
    [
      'seek +10s',
      async () => {
        const current = ref.current?.getCurrentTime() ?? 0
        const started = Date.now()
        await ref.current?.seek(current + 10)
        setSeekResult(`seek resolved in ${Date.now() - started}ms`)
      },
    ],
    [
      'seek 0',
      async () => {
        await ref.current?.seek(0)
        setSeekResult('seek(0) resolved')
      },
    ],
    [
      'time?',
      () => setTime(`${ref.current?.getCurrentTime().toFixed(2) ?? '—'}s`),
    ],
    ['swap source', () => setSourceIndex((index) => (index + 1) % 2)],
  ]

  return (
    <View style={styles.container}>
      <VideoView
        ref={ref}
        source={SOURCES[sourceIndex] ?? SOURCES[0]}
        poster={POSTER}
        muted
        loop
        style={styles.video}
        onPlaybackStateChange={setState}
      />

      <View style={styles.row}>
        {actions.map(([label, action]) => (
          <Pressable key={label} onPress={action} style={styles.button}>
            <Text style={styles.buttonText}>{label}</Text>
          </Pressable>
        ))}
      </View>

      <View style={styles.info}>
        <Text style={styles.infoText}>
          state: {state ? `${state.status} (${state.reason})` : '—'}
        </Text>
        <Text style={styles.infoText}>time: {time}</Text>
        <Text style={styles.infoText}>{seekResult}</Text>
      </View>
    </View>
  )
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  video: {
    aspectRatio: 16 / 9,
    backgroundColor: '#000',
    width: '100%',
  },
  row: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 8,
    padding: 12,
  },
  button: {
    backgroundColor: '#333',
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 6,
  },
  buttonText: {
    color: '#fff',
    fontSize: 13,
  },
  info: {
    gap: 4,
    padding: 12,
  },
  infoText: {
    color: '#9f9',
    fontFamily: 'Menlo',
    fontSize: 12,
  },
})
