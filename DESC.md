# Explorer — GPX Route Manager

## Project Overview

Explorer is a Rails application for displaying and managing GPX routes. Users can upload raw GPX files or sync routes from Google Drive, view detailed route information with maps (via gpx.studio iframe integration), and allocate routes to a weekly calendar using drag-and-drop.

## MVP Features

1. **Authentication** — Authorized users (Devise) can sign up/sign in
2. **Route Upload** — Upload raw GPX files (ActiveStorage)
3. **Google Drive Sync** — Sync routes from Google Drive (Google Drive API)
4. **Route Detail Page** — View detailed route info (distance, elevation, duration) with map rendered via gpx.studio iframe
5. **Weekly Calendar** — Each user has a personal calendar to allocate routes to days of the week (drag-and-drop)
6. **Public Calendar** — Optional public read-only calendar via shareable token URL

## Tech Stack

| Component      | Technology                                           |
| -------------- | ---------------------------------------------------- |
| Framework      | Rails 7.2.2                                          |
| Database       | PostgreSQL                                           |
| Authentication | Devise                                               |
| File Storage   | ActiveStorage (local in dev)                         |
| GPX Parsing    | `gpx` gem                                            |
| Google Drive   | `google-apis-drive_v3`, `googleauth`                 |
| Frontend       | Turbo, Stimulus, jsbundling-rails, cssbundling-rails |
| Code Quality   | RuboCop (omakase), Brakeman                          |

## Data Models

### User

- **Authentication**: Devise (email/password)
- **Fields**: `name`, `email`, `calendar_public` (boolean), `public_token` (string)
- **Google OAuth**: `google_uid`, `google_refresh_token`, `google_access_token`, `google_token_expires_at`
- **Associations**: `has_many :routes, dependent: :destroy`, `has_many :calendar_entries, dependent: :destroy`
- **Callbacks**: `before_save :ensure_public_token` — generates/clears public_token based on `calendar_public` toggle

### Route

- **Fields**: `title`, `description`, `distance` (float), `elevation_gain` (float), `elevation_loss` (float), `min_elevation` (float), `max_elevation` (float), `duration` (integer), `source` (string: "upload" or "google_drive"), `google_drive_file_id` (string)
- **File**: `has_one_attached :gpx_file` (ActiveStorage)
- **Associations**: `belongs_to :user`, `has_many :calendar_entries` (planned)
- **Methods**: `parse_gpx!` — parses attached GPX file and populates stats fields (distance, duration, elevation data)
- **Validations**: `title` presence, `source` inclusion in `["upload", "google_drive"]`

### CalendarEntry

- **Fields**: `day_of_week` (integer 0-6, 0=Sunday), `start_time` (time), `end_time` (time), `notes` (text)
- **Associations**: `belongs_to :user`, `belongs_to :route`
- **Validations**: `day_of_week` presence + inclusion (0-6), `start_time`/`end_time` presence, `end_time` must be after `start_time`
- **Constants**: `DAYS_OF_WEEK` — `["Sunday", "Monday", ..., "Saturday"]`

## Architecture Decisions

### GPX Parsing

- Uses the `gpx` gem (`GPX::GPXFile`) to parse uploaded files
- Stats computed: distance, duration, min/max elevation, elevation gain/loss
- Elevation gain/loss computed by iterating consecutive points and summing positive/negative deltas
- Helper methods (`compute_elevation_gain`, `compute_elevation_loss`) are private — internal implementation only

### gpx.studio Integration

- Route detail page embeds gpx.studio via iframe (https://gpx.studio/help/integration)
- GPX file URL passed to iframe for map rendering

### Google Drive Sync

- OAuth2 flow using `googleauth` gem
- Tokens stored on User model (`google_refresh_token`, `google_access_token`, `google_token_expires_at`)
- Uses `google-apis-drive_v3` to list/download GPX files from user's Drive

### Calendar

- Weekly view (7 days, Sunday-Saturday)
- Drag-and-drop UI for allocating routes to days (owner only)
- Public read-only access via `public_token` URL (no authentication required)
- Every visible route can be downloaded as gpx and can be added to your calendar
- Token auto-generated when `calendar_public` is toggled on, cleared when toggled off

### `dependent: :destroy`

- User deletion cascades to destroy Routes and CalendarEntries
- Uses `:destroy` (not `:delete`) to ensure ActiveStorage callbacks fire and clean up GPX files from storage

## Database Migrations

| Migration                                   | Description                                                    |
| ------------------------------------------- | -------------------------------------------------------------- |
| `20260821063549_devise_create_users.rb`     | Users table with Devise fields + calendar/Google OAuth columns |
| `20260821072432_create_routes.rb`           | Routes table with stats fields and Google Drive reference      |
| `20260821073859_create_calendar_entries.rb` | Calendar entries linking users, routes, and weekly schedule    |

## Git Workflow

- **Branch**: `feature/user-auth-devise` (current)
- **Remote**: `git@github.com:addicted-cyclist/explorer.git`
- **Commit style**: Small, atomic commits with descriptive messages (e.g., "Set up Route model with GPX file uploads")

## Remaining Work

- [x] Commit Route and CalendarEntry model setups (atomic commits)
- [ ] Add `has_many :calendar_entries` to Route model
- [ ] Set up Google Drive OAuth and sync service
- [ ] Create controllers (RoutesController, CalendarController, GoogleDriveController)
- [ ] Create views (route list, route detail with gpx.studio iframe, calendar)
- [ ] Implement drag-and-drop calendar (Stimulus controller)
- [ ] Implement public calendar view (token-based access)
- [ ] Add navigation, styling, and root route
- [ ] Run migrations and test the application

## Development

```bash
# Install dependencies
bundle install

# Setup database
bin/rails db:create db:migrate

# Start server
bin/rails server
```

## Key File Locations

- Models: `app/models/`
- Controllers: `app/controllers/` (to be created)
- Views: `app/views/` (to be created)
- Migrations: `db/migrate/`
- Routes config: `config/routes.rb`
- Devise config: `config/initializers/devise.rb`
