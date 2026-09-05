import { RelayError, MAX_PAGE } from './protocol.mjs';

export class RelayStore {
  constructor(query) { this.query = query; }
  async permitRequest() {
    const [row] = await this.query("SELECT fc_take('requests-minute',600,60) AND fc_take('requests-day',20000,86400) AS allowed", []);
    if (!row.allowed) throw new RelayError('Relay request budget reached; try again later', 429);
  }
  async meta() { return (await this.query('SELECT epoch,event_count,stored_bytes FROM fc_meta WHERE singleton', []))[0]; }
  async insert(event) {
    try {
      const [row] = await this.query('SELECT fc_accept($1::jsonb,$2::integer) AS result', [JSON.stringify(event), Buffer.byteLength(JSON.stringify(event))]);
      return row.result;
    } catch (error) {
      const known = { 'unknown-community': ['Publish the community first',400], 'invalid-parent': ['Reply must reference a message in this community',400],
        'publish-rate': ['Publishing rate reached: 30 new events per signing key per hour',429], 'relay-capacity': ['Pilot relay storage is full',507] };
      if (known[error.message]) throw new RelayError(...known[error.message]);
      throw error;
    }
  }
  async page(offset, kind = null) {
    const [snapshot] = await this.query(`SELECT epoch,
      (SELECT count(*)::integer FROM fc_events WHERE ($2::text IS NULL OR kind=$2)) AS count,
      (SELECT coalesce(jsonb_agg(t.event ORDER BY t.seq),'[]'::jsonb) FROM
        (SELECT seq,event FROM fc_events WHERE ($2::text IS NULL OR kind=$2) ORDER BY seq OFFSET $1::integer LIMIT 64) t) AS events
      FROM fc_meta WHERE singleton`, [offset,kind]);
    if (offset > snapshot.count) throw new RelayError('Offset exceeds relay history; refresh discovery',409);
    const events = []; let bytes = 256;
    for (const event of snapshot.events) {
      const length = Buffer.byteLength(JSON.stringify(event)) + 1;
      if (events.length && bytes + length > MAX_PAGE) break;
      events.push(event); bytes += length;
    }
    const cursor = offset + events.length;
    return { events, cursor, next: cursor < snapshot.count ? cursor : null, epoch: snapshot.epoch };
  }
}
