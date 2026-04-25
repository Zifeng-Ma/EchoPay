-- =====================================================================
-- 1. AUTH & CUSTOMERS
-- Manages user identity and their specific preferences.
-- =====================================================================
CREATE TABLE customers (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE, -- Links to Supabase auth
  first_name TEXT,
  allergy TEXT[],               -- Array of known allergies, e.g., ARRAY['nuts', 'shellfish']
  dietary_preferences TEXT[],   -- Array of diets, e.g., ARRAY['vegan', 'halal']
  preferred_language VARCHAR(5) DEFAULT 'en', -- Stores user's language preference, e.g., 'en', 'es-MX'
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE customers IS 'Stores customer-specific data, linked directly to the authentication system.';


-- =====================================================================
-- 2. RESTAURANTS
-- Core table for restaurant-specific configuration and branding.
-- =====================================================================
CREATE TABLE restaurants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id UUID REFERENCES auth.users(id) ON DELETE SET NULL, -- Restaurant owner's auth ID
  name TEXT NOT NULL,
  description TEXT,
  agent_name TEXT DEFAULT 'Echo', -- The customizable name for the AI agent
  opening_hours JSONB,          -- Flexible JSON for opening times, e.g., {"monday": "09:00-22:00"}
  default_language VARCHAR(5) DEFAULT 'en', -- The primary language for the restaurant
  currency VARCHAR(3) DEFAULT 'EUR',      -- Currency code, e.g., EUR, USD
  bunq_recipient_alias TEXT,    -- Merchant payment destination, e.g., sugardaddy@bunq.com in sandbox
  bunq_recipient_alias_type TEXT DEFAULT 'EMAIL', -- bunq pointer type: EMAIL, PHONE_NUMBER, IBAN
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE restaurants IS 'Holds all configuration data for a single restaurant.';


-- =====================================================================
-- 2b. BUNQ CONNECTIONS
-- Links an EchoPay customer account to a bunq account authorized by OAuth.
-- =====================================================================
CREATE TABLE bunq_connections (
  customer_id UUID PRIMARY KEY REFERENCES customers(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'connected',
  bunq_user_id TEXT,
  access_token_encrypted TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE bunq_connections IS 'Stores backend-only bunq OAuth connection metadata for customer-authorized payments.';


-- =====================================================================
-- 3. QR LOCATIONS
-- Defines scannable points within a restaurant (tables, counters).
-- =====================================================================
CREATE TABLE qr_locations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  location_name TEXT NOT NULL,  -- More descriptive than a number, e.g., "Table 5", "Counter"
  qr_code_hash TEXT UNIQUE NOT NULL, -- The unique identifier embedded in the QR code
  is_active BOOLEAN DEFAULT TRUE
);

COMMENT ON TABLE qr_locations IS 'Represents a physical location in a restaurant tied to a QR code.';


-- =====================================================================
-- 4. MENU & MODIFIERS
-- Detailed structure for menu items and their customizations.
-- =====================================================================

-- Menu Items Table
CREATE TABLE menu_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  name_translations JSONB,        -- For multilingual support, e.g., {"es": "Lasaña", "fr": "Lasagne"}
  description_translations JSONB,
  category TEXT,                  -- E.g., 'Starters', 'Mains', 'Drinks'
  price INTEGER NOT NULL,         -- Stored in cents (e.g., 1050 for €10.50)
  inventory_count INTEGER,        -- Use NULL for unlimited items like drinks
  dietary_tags TEXT[],            -- E.g., ARRAY['vegan', 'gluten-free']
  is_available BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE menu_items IS 'Stores all individual items available for sale, with multilingual support.';

-- Modifier Groups Table (e.g., "Choose your size", "Add toppings")
CREATE TABLE modifier_groups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  name TEXT NOT NULL              -- E.g., "Pizza Toppings", "Steak Temperature", "Burger Add-ons"
);

COMMENT ON TABLE modifier_groups IS 'Defines a category of choices for a menu item.';

-- Modifiers Table (The actual options, e.g., "Extra Cheese", "Medium Rare")
CREATE TABLE modifiers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID NOT NULL REFERENCES modifier_groups(id) ON DELETE CASCADE,
  name TEXT NOT NULL,             -- E.g., "Extra Cheese", "Bacon", "Avocado"
  price_change INTEGER NOT NULL DEFAULT 0 -- Price difference in cents (can be positive or negative)
);

COMMENT ON TABLE modifiers IS 'A specific choice within a modifier group, with its associated price change.';

-- Link table to associate menu items with modifier groups
CREATE TABLE menu_item_modifiers (
  menu_item_id UUID NOT NULL REFERENCES menu_items(id) ON DELETE CASCADE,
  modifier_group_id UUID NOT NULL REFERENCES modifier_groups(id) ON DELETE CASCADE,
  PRIMARY KEY (menu_item_id, modifier_group_id)
);

COMMENT ON TABLE menu_item_modifiers IS 'Links which modifier groups are available for a specific menu item.';


-- =====================================================================
-- 5. ORDERS & FULFILLMENT
-- Manages the entire lifecycle of a customer order.
-- =====================================================================

-- Using an ENUM type enforces a clear and finite set of states for an order.
CREATE TYPE order_status_enum AS ENUM (
  'draft',            -- The order is being built (acting as a shopping cart)
  'pending_payment',  -- User has confirmed order, waiting for bunq approval
  'confirmed',        -- Payment successful, ready for kitchen
  'in_progress',      -- Kitchen is preparing the order
  'ready_for_delivery',-- Order is ready for pickup by a waiter
  'completed',        -- Order has been delivered to the customer
  'cancelled'         -- Order has been cancelled
);

-- Orders Table
CREATE TABLE orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  customer_id UUID REFERENCES customers(id) ON DELETE SET NULL, -- Nullable for guests
  qr_location_id UUID REFERENCES qr_locations(id) ON DELETE SET NULL, -- Where the order goes
  order_status order_status_enum NOT NULL DEFAULT 'draft',
  total_amount INTEGER NOT NULL, -- Stored in cents, calculated from order items and modifiers
  bunq_transaction_id TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE orders IS 'High-level information for a single customer order.';

-- Order Items Table
CREATE TABLE order_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  menu_item_id UUID REFERENCES menu_items(id) ON DELETE SET NULL,
  quantity INTEGER NOT NULL DEFAULT 1,
  special_instructions TEXT,    -- User-provided notes, e.g., "Allergic to cilantro"
  price_at_purchase INTEGER NOT NULL -- The base price of the item in cents when ordered
);

COMMENT ON TABLE order_items IS 'Details of each specific menu item within an order.';

-- Order Item Modifiers Table (Records which modifiers were chosen)
CREATE TABLE order_item_modifiers (
  order_item_id UUID NOT NULL REFERENCES order_items(id) ON DELETE CASCADE,
  modifier_id UUID NOT NULL REFERENCES modifiers(id) ON DELETE CASCADE,
  PRIMARY KEY (order_item_id, modifier_id)
);

COMMENT ON TABLE order_item_modifiers IS 'Records the specific customizations chosen for an item in an order.';
