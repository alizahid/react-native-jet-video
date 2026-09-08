import type { NativeStackScreenProps } from '@react-navigation/native-stack'
import { FlashList } from '@shopify/flash-list'
import { useCallback, useEffect, useRef, useState } from 'react'
import { Pressable, StyleSheet, Text, View } from 'react-native'
import {
  getPlayerPoolStats,
  type PlaybackStatus,
  VideoView,
  type VideoViewRef,
} from 'react-native-jet-video'
import type { RootStackParamList } from '../App'
import { VIDEOS } from '../videos'

interface FeedItem {
  id: number
  uri: string
  aspectRatio: number
}

const ITEMS: FeedItem[] = Array.from({ length: 200 }, (_, index) => ({
  id: index,
  uri: VIDEOS[index % VIDEOS.length] as string,
  // Alternate tall and short cells: a tall video half-hidden under the
  // transparent header must not outrank the short one fully visible below.
  aspectRatio: index % 2 === 0 ? 4 / 5 : 16 / 9,
}))

function FeedCell({ item, depth }: { item: FeedItem; depth: number }) {
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
          // Distinct players per screen: the feed cycles three URIs, so
          // without this every pushed feed would share the same three.
          playerKey={`${depth}-${item.id}`}
          autoplay="whenVisible"
          muted
          loop
          style={[styles.video, { aspectRatio: item.aspectRatio }]}
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

/**
 * Pushes onto itself without limit, so a deep stack of feeds (every one
 * mounted, none visible) can be checked against the player pool: the pool
 * readout in the header must stay bounded no matter the depth.
 */
export function Feed({
  navigation,
  route,
}: Partial<NativeStackScreenProps<RootStackParamList, 'Feed'>>) {
  const depth = route?.params?.depth ?? 1
  const [stats, setStats] = useState('')

  useEffect(() => {
    const timer = setInterval(async () => {
      const pool = await getPlayerPoolStats()
      setStats(`pool ${pool.players} · live ${pool.liveItems}`)
    }, 500)
    return () => clearInterval(timer)
  }, [])

  useEffect(() => {
    navigation?.setOptions({
      title: `Feed ${depth} · ${stats}`,
      headerBlurEffect: 'systemChromeMaterialDark',
      headerTransparent: true,
      headerRight: () => (
        <Pressable
          onPress={() => navigation.push('Feed', { depth: depth + 1 })}
          testID="push-feed"
        >
          <Text style={styles.push}>Push ›</Text>
        </Pressable>
      ),
    })
  }, [navigation, depth, stats])

  return (
    <FlashList
      contentInsetAdjustmentBehavior="automatic"
      data={ITEMS}
      keyExtractor={(item) => String(item.id)}
      renderItem={({ item }) => <FeedCell depth={depth} item={item} />}
    />
  )
}

const styles = StyleSheet.create({
  push: {
    color: '#5e9eff',
    fontSize: 16,
    fontWeight: '600',
  },
  cell: {
    marginBottom: 24,
  },
  video: {
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
