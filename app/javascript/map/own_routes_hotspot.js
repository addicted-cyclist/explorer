// My Map viewport target — the densest own-routes hotspot.
//
// Both the page's initial viewport (technote §3.1) and the heart control's
// "return to my routes" action (§3.2) land on the place where the rider
// actually has the most routes, instead of zooming out to frame every track
// they own.
// Every route's bounds-box center is one vote: the best-attended route —
// the one with the most other centers within HOTSPOT_RADIUS_KM — anchors
// the hotspot, and the union box of that group is returned as a plain
// [w, s, e, n] LngLatBoundsLike for map.fitBounds. So a neighbourhood with
// five short rides beats one long tour that merely passes through, the
// answer cannot be split by an arbitrary grid, ties resolve to the route
// seen first (stable order over the payload), and a map without any usable
// bounds returns null so the caller can fall back to its default view.

// "A place": routes centered within this distance of each other belong to
// the same hotspot. ~5 km covers a city centre or a trailhead area.
const HOTSPOT_RADIUS_KM = 5;
const KM_PER_DEG_LAT = 110.574;
const KM_PER_DEG_LNG = 111.32;

// Own-routes scale only (a user's own list), so the O(n²) neighbourhood
// scan is comfortably cheap and keeps the algorithm grid-artifact-free.
export function ownRoutesHotspotBounds(features) {
  const centers = [];
  const boxes = [];
  features.forEach((feature) => {
    const box = feature.properties && feature.properties.bounds;
    if (!box) return;
    boxes.push(box);
    centers.push([ (box[0] + box[2]) / 2, (box[1] + box[3]) / 2 ]);
  });
  if (centers.length === 0) return null;

  // Best anchor + its neighbours. Longitude degrees shrink with latitude,
  // so distances use the equirectangular approximation (fine at 5 km).
  const radiusSq = HOTSPOT_RADIUS_KM * HOTSPOT_RADIUS_KM;
  let bestGroup = null;
  centers.forEach((anchor, index) => {
    const group = [ index ];
    const kmPerDegLng = KM_PER_DEG_LNG * Math.cos(anchor[1] * Math.PI / 180);
    centers.forEach((center, other) => {
      if (other === index) return;
      const dx = (center[0] - anchor[0]) * kmPerDegLng;
      const dy = (center[1] - anchor[1]) * KM_PER_DEG_LAT;
      if (dx * dx + dy * dy <= radiusSq) group.push(other);
    });
    if (!bestGroup || group.length > bestGroup.length) bestGroup = group;
  });

  const bounds = [ Infinity, Infinity, -Infinity, -Infinity ];
  bestGroup.forEach((index) => {
    const box = boxes[index];
    bounds[0] = Math.min(bounds[0], box[0]);
    bounds[1] = Math.min(bounds[1], box[1]);
    bounds[2] = Math.max(bounds[2], box[2]);
    bounds[3] = Math.max(bounds[3], box[3]);
  });
  return bounds;
}
