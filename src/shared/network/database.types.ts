export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "graphql_public": {
          Tables: {
            [_ in never]: never
          }
          Views: {
            [_ in never]: never
          }
          Functions: {
            "graphql":
{ Args: { "extensions"?: Json,"operationName"?: string,"query"?: string,"variables"?: Json }; Returns: Json
                           }
          }
          Enums: {
            [_ in never]: never
          }
          CompositeTypes: {
            [_ in never]: never
          }
        },"public": {
          Tables: {
            "areas": {
                  Row: {
                    "area_name": string,"asa_id": string | null,"created_at": string,"id": string,"tenant_id": string,"territory_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "area_name": string,"asa_id"?: string | null,"created_at"?: string,"id"?: string,"tenant_id": string,"territory_id": string
                  }
                  Update: {
                    "area_name"?: string,"asa_id"?: string | null,"created_at"?: string,"id"?: string,"tenant_id"?: string,"territory_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "areas_asa_id_fkey"
      columns: ["asa_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "areas_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "areas_tenant_id_territory_id_fkey"
      columns: ["tenant_id","territory_id"]
isOneToOne: false
      referencedRelation: "territories"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"audit_logs": {
                  Row: {
                    "actor_id": string | null,"actor_role": string | null,"after": Json | null,"before": Json | null,"created_at": string,"entity_id": string | null,"entity_type": string,"id": number,"idempotency_key": string | null,"operation": string,"source": Database["public"]['Enums']["audit_source_enum"],"teafair_agent_id": string | null,"tenant_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "actor_id"?: string | null,"actor_role"?: string | null,"after"?: Json | null,"before"?: Json | null,"created_at"?: string,"entity_id"?: string | null,"entity_type": string,"id"?: never,"idempotency_key"?: string | null,"operation": string,"source": Database["public"]['Enums']["audit_source_enum"],"teafair_agent_id"?: string | null,"tenant_id"?: string | null
                  }
                  Update: {
                    "actor_id"?: string | null,"actor_role"?: string | null,"after"?: Json | null,"before"?: Json | null,"created_at"?: string,"entity_id"?: string | null,"entity_type"?: string,"id"?: never,"idempotency_key"?: string | null,"operation"?: string,"source"?: Database["public"]['Enums']["audit_source_enum"],"teafair_agent_id"?: string | null,"tenant_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "audit_logs_actor_id_fkey"
      columns: ["actor_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "audit_logs_teafair_agent_id_fkey"
      columns: ["teafair_agent_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "audit_logs_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"brand_approval_policies": {
                  Row: {
                    "brand": string,"required_approval_level": Database["public"]['Enums']["tenant_role_enum"],"tenant_id": string,"updated_at": string,"updated_by": string
                  }
                  ComputedFields: never
                  Insert: {
                    "brand": string,"required_approval_level": Database["public"]['Enums']["tenant_role_enum"],"tenant_id": string,"updated_at"?: string,"updated_by": string
                  }
                  Update: {
                    "brand"?: string,"required_approval_level"?: Database["public"]['Enums']["tenant_role_enum"],"tenant_id"?: string,"updated_at"?: string,"updated_by"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "brand_approval_policies_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "brand_approval_policies_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"cash_audit_batches": {
                  Row: {
                    "agent_id": string,"created_at": string,"declared_cash_amount": number,"digital_collection_total": number,"id": string,"is_reconciled": boolean,"teller_receipt_number": string,"tenant_id": string,"updated_at": string,"variance_reason": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "agent_id": string,"created_at"?: string,"declared_cash_amount": number,"digital_collection_total": number,"id"?: string,"is_reconciled"?: boolean,"teller_receipt_number": string,"tenant_id": string,"updated_at"?: string,"variance_reason"?: string | null
                  }
                  Update: {
                    "agent_id"?: string,"created_at"?: string,"declared_cash_amount"?: number,"digital_collection_total"?: number,"id"?: string,"is_reconciled"?: boolean,"teller_receipt_number"?: string,"tenant_id"?: string,"updated_at"?: string,"variance_reason"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "cash_audit_batches_agent_id_fkey"
      columns: ["agent_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "cash_audit_batches_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"central_products": {
                  Row: {
                    "brand": string,"break_bulk_units": number | null,"break_bulk_wholesale_price": number | null,"carton_units": number | null,"carton_wholesale_price": number | null,"category": string,"created_at": string,"decision_id": string | null,"description": string | null,"id": string,"is_active": boolean,"nafdac_number": string | null,"product_name": string,"sale_category": string,"sku_code": string,"tenant_id": string,"unit_price": number,"updated_at": string,"wholesale_price": number
                  }
                  ComputedFields: never
                  Insert: {
                    "brand": string,"break_bulk_units"?: number | null,"break_bulk_wholesale_price"?: never,"carton_units"?: number | null,"carton_wholesale_price"?: never,"category": string,"created_at"?: string,"decision_id"?: string | null,"description"?: string | null,"id"?: string,"is_active"?: boolean,"nafdac_number"?: string | null,"product_name": string,"sale_category"?: string,"sku_code": string,"tenant_id": string,"unit_price": number,"updated_at"?: string,"wholesale_price": number
                  }
                  Update: {
                    "brand"?: string,"break_bulk_units"?: number | null,"break_bulk_wholesale_price"?: never,"carton_units"?: number | null,"carton_wholesale_price"?: never,"category"?: string,"created_at"?: string,"decision_id"?: string | null,"description"?: string | null,"id"?: string,"is_active"?: boolean,"nafdac_number"?: string | null,"product_name"?: string,"sale_category"?: string,"sku_code"?: string,"tenant_id"?: string,"unit_price"?: number,"updated_at"?: string,"wholesale_price"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "central_products_decision_fkey"
      columns: ["tenant_id","decision_id"]
isOneToOne: false
      referencedRelation: "contact_report_decisions"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "central_products_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"chat_channels": {
                  Row: {
                    "channel_type": string,"created_at": string,"direct_high_id": string | null,"direct_low_id": string | null,"id": string,"last_message_at": string | null,"tenant_id": string,"territory_id": string | null,"zone_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "channel_type": string,"created_at"?: string,"direct_high_id"?: string | null,"direct_low_id"?: string | null,"id"?: string,"last_message_at"?: string | null,"tenant_id": string,"territory_id"?: string | null,"zone_id"?: string | null
                  }
                  Update: {
                    "channel_type"?: string,"created_at"?: string,"direct_high_id"?: string | null,"direct_low_id"?: string | null,"id"?: string,"last_message_at"?: string | null,"tenant_id"?: string,"territory_id"?: string | null,"zone_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "chat_channels_direct_high_id_fkey"
      columns: ["direct_high_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "chat_channels_direct_low_id_fkey"
      columns: ["direct_low_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "chat_channels_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "chat_channels_tenant_id_territory_id_fkey"
      columns: ["tenant_id","territory_id"]
isOneToOne: false
      referencedRelation: "territories"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "chat_channels_tenant_id_zone_id_fkey"
      columns: ["tenant_id","zone_id"]
isOneToOne: false
      referencedRelation: "zones"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"chat_messages": {
                  Row: {
                    "body": string,"channel_id": string,"created_at": string,"hidden_at": string | null,"hidden_by": string | null,"id": string,"sender_id": string,"tenant_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "body": string,"channel_id": string,"created_at"?: string,"hidden_at"?: string | null,"hidden_by"?: string | null,"id"?: string,"sender_id": string,"tenant_id": string
                  }
                  Update: {
                    "body"?: string,"channel_id"?: string,"created_at"?: string,"hidden_at"?: string | null,"hidden_by"?: string | null,"id"?: string,"sender_id"?: string,"tenant_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "chat_messages_hidden_by_fkey"
      columns: ["hidden_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "chat_messages_sender_id_fkey"
      columns: ["sender_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "chat_messages_tenant_id_channel_id_fkey"
      columns: ["tenant_id","channel_id"]
isOneToOne: false
      referencedRelation: "chat_channels"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "chat_messages_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"chat_read_state": {
                  Row: {
                    "channel_id": string,"last_read_at": string,"profile_id": string,"tenant_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "channel_id": string,"last_read_at": string,"profile_id": string,"tenant_id": string
                  }
                  Update: {
                    "channel_id"?: string,"last_read_at"?: string,"profile_id"?: string,"tenant_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "chat_read_state_profile_id_fkey"
      columns: ["profile_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "chat_read_state_tenant_id_channel_id_fkey"
      columns: ["tenant_id","channel_id"]
isOneToOne: false
      referencedRelation: "chat_channels"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "chat_read_state_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"contact_report_decisions": {
                  Row: {
                    "created_at": string,"decision_text": string,"id": string,"report_id": string,"seq": number,"subject": string,"tenant_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"decision_text": string,"id"?: string,"report_id": string,"seq": number,"subject": string,"tenant_id": string
                  }
                  Update: {
                    "created_at"?: string,"decision_text"?: string,"id"?: string,"report_id"?: string,"seq"?: number,"subject"?: string,"tenant_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "contact_report_decisions_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "contact_report_decisions_tenant_id_report_id_fkey"
      columns: ["tenant_id","report_id"]
isOneToOne: false
      referencedRelation: "contact_reports"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"contact_report_deliveries": {
                  Row: {
                    "attempts": number,"channel": string,"created_at": string,"error_code": string | null,"id": string,"last_attempt_at": string | null,"recipient_id": string,"report_id": string,"sent_at": string | null,"status": string,"tenant_id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "attempts"?: number,"channel": string,"created_at"?: string,"error_code"?: string | null,"id"?: string,"last_attempt_at"?: string | null,"recipient_id": string,"report_id": string,"sent_at"?: string | null,"status"?: string,"tenant_id": string,"updated_at"?: string
                  }
                  Update: {
                    "attempts"?: number,"channel"?: string,"created_at"?: string,"error_code"?: string | null,"id"?: string,"last_attempt_at"?: string | null,"recipient_id"?: string,"report_id"?: string,"sent_at"?: string | null,"status"?: string,"tenant_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "contact_report_deliveries_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "contact_report_deliveries_tenant_id_recipient_id_fkey"
      columns: ["tenant_id","recipient_id"]
isOneToOne: false
      referencedRelation: "contact_report_recipients"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "contact_report_deliveries_tenant_id_report_id_fkey"
      columns: ["tenant_id","report_id"]
isOneToOne: false
      referencedRelation: "contact_reports"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"contact_report_hard_copies": {
                  Row: {
                    "attached_at": string | null,"created_at": string,"id": string,"mime_type": string,"report_id": string,"size_bytes": number,"storage_path": string,"tenant_id": string,"uploaded_by": string
                  }
                  ComputedFields: never
                  Insert: {
                    "attached_at"?: string | null,"created_at"?: string,"id"?: string,"mime_type": string,"report_id": string,"size_bytes": number,"storage_path": string,"tenant_id": string,"uploaded_by": string
                  }
                  Update: {
                    "attached_at"?: string | null,"created_at"?: string,"id"?: string,"mime_type"?: string,"report_id"?: string,"size_bytes"?: number,"storage_path"?: string,"tenant_id"?: string,"uploaded_by"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "contact_report_hard_copies_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "contact_report_hard_copies_tenant_id_report_id_fkey"
      columns: ["tenant_id","report_id"]
isOneToOne: false
      referencedRelation: "contact_reports"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "contact_report_hard_copies_uploaded_by_fkey"
      columns: ["uploaded_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"contact_report_recipients": {
                  Row: {
                    "address": string,"address_hint": string,"channel": string,"created_at": string,"id": string,"name": string,"report_id": string,"tenant_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "address": string,"address_hint": string,"channel": string,"created_at"?: string,"id"?: string,"name": string,"report_id": string,"tenant_id": string
                  }
                  Update: {
                    "address"?: string,"address_hint"?: string,"channel"?: string,"created_at"?: string,"id"?: string,"name"?: string,"report_id"?: string,"tenant_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "contact_report_recipients_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "contact_report_recipients_tenant_id_report_id_fkey"
      columns: ["tenant_id","report_id"]
isOneToOne: false
      referencedRelation: "contact_reports"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"contact_report_reviews": {
                  Row: {
                    "id": string,"note": string | null,"outcome": string,"report_id": string,"reviewed_at": string,"reviewed_by": string,"reviewer_kind": string,"tenant_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "id"?: string,"note"?: string | null,"outcome": string,"report_id": string,"reviewed_at"?: string,"reviewed_by": string,"reviewer_kind"?: string,"tenant_id": string
                  }
                  Update: {
                    "id"?: string,"note"?: string | null,"outcome"?: string,"report_id"?: string,"reviewed_at"?: string,"reviewed_by"?: string,"reviewer_kind"?: string,"tenant_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "contact_report_reviews_reviewed_by_fkey"
      columns: ["reviewed_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "contact_report_reviews_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "contact_report_reviews_tenant_id_report_id_fkey"
      columns: ["tenant_id","report_id"]
isOneToOne: false
      referencedRelation: "contact_reports"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"contact_reports": {
                  Row: {
                    "attendees": NonNullable<Json>,"channel": string,"filed_at": string,"filed_by": string,"id": string,"met_at": string,"reference": string,"summary": string,"supersedes_id": string | null,"tenant_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "attendees": NonNullable<Json>,"channel": string,"filed_at"?: string,"filed_by": string,"id"?: string,"met_at": string,"reference": string,"summary": string,"supersedes_id"?: string | null,"tenant_id": string
                  }
                  Update: {
                    "attendees"?: NonNullable<Json>,"channel"?: string,"filed_at"?: string,"filed_by"?: string,"id"?: string,"met_at"?: string,"reference"?: string,"summary"?: string,"supersedes_id"?: string | null,"tenant_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "contact_reports_filed_by_fkey"
      columns: ["filed_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "contact_reports_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "contact_reports_tenant_id_supersedes_id_fkey"
      columns: ["tenant_id","supersedes_id"]
isOneToOne: false
      referencedRelation: "contact_reports"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"devices": {
                  Row: {
                    "created_at": string,"device_model": string | null,"hardware_id": string,"id": string,"last_seen_at": string,"push_token": string | null,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"device_model"?: string | null,"hardware_id": string,"id"?: string,"last_seen_at"?: string,"push_token"?: string | null,"user_id": string
                  }
                  Update: {
                    "created_at"?: string,"device_model"?: string | null,"hardware_id"?: string,"id"?: string,"last_seen_at"?: string,"push_token"?: string | null,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "devices_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"email_outbox": {
                  Row: {
                    "attempts": number,"created_at": string,"id": string,"next_attempt_at": string,"payload": NonNullable<Json>,"sent_at": string | null,"source_id": string,"source_table": string,"status": string,"template": string,"to_email": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "attempts"?: number,"created_at"?: string,"id"?: string,"next_attempt_at"?: string,"payload": NonNullable<Json>,"sent_at"?: string | null,"source_id": string,"source_table": string,"status"?: string,"template": string,"to_email"?: string | null
                  }
                  Update: {
                    "attempts"?: number,"created_at"?: string,"id"?: string,"next_attempt_at"?: string,"payload"?: NonNullable<Json>,"sent_at"?: string | null,"source_id"?: string,"source_table"?: string,"status"?: string,"template"?: string,"to_email"?: string | null
                  }
                  Relationships: [
                    
                  ]
                },"field_check_ins": {
                  Row: {
                    "captured_at": string,"created_at": string,"id": string,"location": unknown,"route_id": string | null,"tenant_id": string,"user_id": string,"waypoint_id": string | null,"within_geofence": boolean
                  }
                  ComputedFields: never
                  Insert: {
                    "captured_at": string,"created_at"?: string,"id"?: string,"location": unknown,"route_id"?: string | null,"tenant_id": string,"user_id": string,"waypoint_id"?: string | null,"within_geofence": boolean
                  }
                  Update: {
                    "captured_at"?: string,"created_at"?: string,"id"?: string,"location"?: unknown,"route_id"?: string | null,"tenant_id"?: string,"user_id"?: string,"waypoint_id"?: string | null,"within_geofence"?: boolean
                  }
                  Relationships: [
                    {
      foreignKeyName: "field_check_ins_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "field_check_ins_tenant_id_route_id_fkey"
      columns: ["tenant_id","route_id"]
isOneToOne: false
      referencedRelation: "routes"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "field_check_ins_tenant_id_waypoint_id_fkey"
      columns: ["tenant_id","waypoint_id"]
isOneToOne: false
      referencedRelation: "route_waypoints"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "field_check_ins_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"idempotency_logs": {
                  Row: {
                    "actor_id": string | null,"created_at": string,"key": string,"operation": string,"request_hash": string,"response": Json | null,"status": string,"tenant_id": string | null,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "actor_id"?: string | null,"created_at"?: string,"key": string,"operation": string,"request_hash": string,"response"?: Json | null,"status"?: string,"tenant_id"?: string | null,"updated_at"?: string
                  }
                  Update: {
                    "actor_id"?: string | null,"created_at"?: string,"key"?: string,"operation"?: string,"request_hash"?: string,"response"?: Json | null,"status"?: string,"tenant_id"?: string | null,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "idempotency_logs_actor_id_fkey"
      columns: ["actor_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "idempotency_logs_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"inventory_batches": {
                  Row: {
                    "batch_number": string,"created_at": string,"expires_at": string | null,"id": string,"quantity": number,"quantity_reserved": number,"sku_code": string,"tenant_id": string,"updated_at": string,"warehouse_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "batch_number": string,"created_at"?: string,"expires_at"?: string | null,"id"?: string,"quantity": number,"quantity_reserved"?: number,"sku_code": string,"tenant_id": string,"updated_at"?: string,"warehouse_id": string
                  }
                  Update: {
                    "batch_number"?: string,"created_at"?: string,"expires_at"?: string | null,"id"?: string,"quantity"?: number,"quantity_reserved"?: number,"sku_code"?: string,"tenant_id"?: string,"updated_at"?: string,"warehouse_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "inventory_batches_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "inventory_batches_tenant_id_sku_code_fkey"
      columns: ["tenant_id","sku_code"]
isOneToOne: false
      referencedRelation: "central_products"
      referencedColumns: ["tenant_id","sku_code"]
    },{
      foreignKeyName: "inventory_batches_tenant_id_warehouse_id_fkey"
      columns: ["tenant_id","warehouse_id"]
isOneToOne: false
      referencedRelation: "warehouses"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"monvelo_agent_members": {
                  Row: {
                    "agent_id": string,"created_at": string,"profile_id": string,"status": string
                  }
                  ComputedFields: never
                  Insert: {
                    "agent_id": string,"created_at"?: string,"profile_id": string,"status"?: string
                  }
                  Update: {
                    "agent_id"?: string,"created_at"?: string,"profile_id"?: string,"status"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_agent_members_agent_id_fkey"
      columns: ["agent_id"]
isOneToOne: false
      referencedRelation: "monvelo_agents"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_agent_members_profile_id_fkey"
      columns: ["profile_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_agent_nominations": {
                  Row: {
                    "created_at": string,"id": string,"nominated_name": string,"nominated_phone_last4": string,"pos_network": Database["public"]['Enums']["pos_network_enum"],"raised_by": string,"recruited_agent_id": string | null,"shop_id": string,"status": string,"tenant_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"id"?: string,"nominated_name": string,"nominated_phone_last4": string,"pos_network": Database["public"]['Enums']["pos_network_enum"],"raised_by": string,"recruited_agent_id"?: string | null,"shop_id": string,"status"?: string,"tenant_id": string
                  }
                  Update: {
                    "created_at"?: string,"id"?: string,"nominated_name"?: string,"nominated_phone_last4"?: string,"pos_network"?: Database["public"]['Enums']["pos_network_enum"],"raised_by"?: string,"recruited_agent_id"?: string | null,"shop_id"?: string,"status"?: string,"tenant_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_agent_nominations_raised_by_fkey"
      columns: ["raised_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_agent_nominations_recruited_agent_id_fkey"
      columns: ["recruited_agent_id"]
isOneToOne: false
      referencedRelation: "monvelo_agents"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_agent_nominations_shop_id_fkey"
      columns: ["shop_id"]
isOneToOne: false
      referencedRelation: "retail_shops"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_agent_nominations_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_agent_nominations_tenant_id_shop_id_fkey"
      columns: ["tenant_id","shop_id"]
isOneToOne: false
      referencedRelation: "monvelo_shop_enrolments"
      referencedColumns: ["tenant_id","shop_id"]
    }
                  ]
                },"monvelo_agents": {
                  Row: {
                    "address_text": string,"approved_at": string | null,"approved_by": string | null,"business_name": string,"contact_phone": string,"created_at": string,"daily_cap": number,"id": string,"location": unknown,"network_agent_id": string,"network_kyc_reference": string,"partner_code": string,"partner_kind": string,"paystack_payer_ref": string | null,"pending_settlement": Json | null,"per_financing_cap": number,"pos_network": Database["public"]['Enums']["pos_network_enum"],"recruited_by": string,"settlement_account_last4": string,"settlement_account_name": string,"settlement_account_number": string,"settlement_bank_code": string,"status": string,"updated_at": string,"monvelo_agent_audit": Json | null
                  }
                  ComputedFields: "monvelo_agent_audit"
                  Insert: {
                    "address_text": string,"approved_at"?: string | null,"approved_by"?: string | null,"business_name": string,"contact_phone": string,"created_at"?: string,"daily_cap"?: number,"id"?: string,"location": unknown,"network_agent_id": string,"network_kyc_reference": string,"partner_code"?: string,"partner_kind"?: string,"paystack_payer_ref"?: string | null,"pending_settlement"?: Json | null,"per_financing_cap"?: number,"pos_network": Database["public"]['Enums']["pos_network_enum"],"recruited_by": string,"settlement_account_last4": string,"settlement_account_name": string,"settlement_account_number": string,"settlement_bank_code": string,"status"?: string,"updated_at"?: string
                  }
                  Update: {
                    "address_text"?: string,"approved_at"?: string | null,"approved_by"?: string | null,"business_name"?: string,"contact_phone"?: string,"created_at"?: string,"daily_cap"?: number,"id"?: string,"location"?: unknown,"network_agent_id"?: string,"network_kyc_reference"?: string,"partner_code"?: string,"partner_kind"?: string,"paystack_payer_ref"?: string | null,"pending_settlement"?: Json | null,"per_financing_cap"?: number,"pos_network"?: Database["public"]['Enums']["pos_network_enum"],"recruited_by"?: string,"settlement_account_last4"?: string,"settlement_account_name"?: string,"settlement_account_number"?: string,"settlement_bank_code"?: string,"status"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_agents_approved_by_fkey"
      columns: ["approved_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_agents_recruited_by_fkey"
      columns: ["recruited_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_brand_terms": {
                  Row: {
                    "approval_decision_id": string | null,"approved_at": string | null,"approved_by": string | null,"brand": string,"brand_key": string | null,"created_at": string,"id": string,"interest_free_days": number,"late_charge_bps": number,"proposed_by": string,"rebate_bps": number,"status": string,"tenant_id": string,"valid_from": string,"valid_to": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "approval_decision_id"?: string | null,"approved_at"?: string | null,"approved_by"?: string | null,"brand": string,"brand_key"?: never,"created_at"?: string,"id"?: string,"interest_free_days"?: number,"late_charge_bps"?: number,"proposed_by": string,"rebate_bps": number,"status"?: string,"tenant_id": string,"valid_from": string,"valid_to"?: string | null
                  }
                  Update: {
                    "approval_decision_id"?: string | null,"approved_at"?: string | null,"approved_by"?: string | null,"brand"?: string,"brand_key"?: never,"created_at"?: string,"id"?: string,"interest_free_days"?: number,"late_charge_bps"?: number,"proposed_by"?: string,"rebate_bps"?: number,"status"?: string,"tenant_id"?: string,"valid_from"?: string,"valid_to"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_brand_terms_approved_by_fkey"
      columns: ["approved_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_brand_terms_decision_fkey"
      columns: ["tenant_id","approval_decision_id"]
isOneToOne: false
      referencedRelation: "contact_report_decisions"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_brand_terms_proposed_by_fkey"
      columns: ["proposed_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_brand_terms_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_claim_holds": {
                  Row: {
                    "agent_id": string,"blocks": (string)[],"claimed_by": string,"created_at": string,"decided_at": string | null,"decided_by": string | null,"expires_at": string,"exposure_after": number,"exposure_before": number,"financing_id": string,"id": string,"pledge_remaining": number,"quoted_net_yield_bps": number | null,"reason": string | null,"status": string,"tenant_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "agent_id": string,"blocks": (string)[],"claimed_by": string,"created_at"?: string,"decided_at"?: string | null,"decided_by"?: string | null,"expires_at": string,"exposure_after": number,"exposure_before": number,"financing_id": string,"id"?: string,"pledge_remaining": number,"quoted_net_yield_bps"?: number | null,"reason"?: string | null,"status"?: string,"tenant_id": string
                  }
                  Update: {
                    "agent_id"?: string,"blocks"?: (string)[],"claimed_by"?: string,"created_at"?: string,"decided_at"?: string | null,"decided_by"?: string | null,"expires_at"?: string,"exposure_after"?: number,"exposure_before"?: number,"financing_id"?: string,"id"?: string,"pledge_remaining"?: number,"quoted_net_yield_bps"?: number | null,"reason"?: string | null,"status"?: string,"tenant_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_claim_holds_agent_id_fkey"
      columns: ["agent_id"]
isOneToOne: false
      referencedRelation: "monvelo_agents"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_claim_holds_claimed_by_fkey"
      columns: ["claimed_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_claim_holds_decided_by_fkey"
      columns: ["decided_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_claim_holds_tenant_id_financing_id_fkey"
      columns: ["tenant_id","financing_id"]
isOneToOne: false
      referencedRelation: "monvelo_financings"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_claim_holds_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_consent_challenges": {
                  Row: {
                    "area_id": string,"code_hash": string,"consumed_at": string | null,"created_at": string,"expires_at": string,"failed_attempts": number,"id": string,"issued_by": string,"purpose": string,"shop_id": string,"tenant_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "area_id": string,"code_hash": string,"consumed_at"?: string | null,"created_at"?: string,"expires_at": string,"failed_attempts"?: number,"id"?: string,"issued_by": string,"purpose"?: string,"shop_id": string,"tenant_id": string
                  }
                  Update: {
                    "area_id"?: string,"code_hash"?: string,"consumed_at"?: string | null,"created_at"?: string,"expires_at"?: string,"failed_attempts"?: number,"id"?: string,"issued_by"?: string,"purpose"?: string,"shop_id"?: string,"tenant_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_consent_challenges_issued_by_fkey"
      columns: ["issued_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_consent_challenges_shop_id_fkey"
      columns: ["shop_id"]
isOneToOne: false
      referencedRelation: "retail_shops"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_consent_challenges_tenant_id_area_id_fkey"
      columns: ["tenant_id","area_id"]
isOneToOne: false
      referencedRelation: "areas"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_consent_challenges_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_financing_claims": {
                  Row: {
                    "agent_id": string,"claimed_at": string,"claimed_by": string,"ended_at": string | null,"expires_at": string,"financing_id": string,"id": string,"outcome": string | null,"pledge_id": string,"tenant_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "agent_id": string,"claimed_at"?: string,"claimed_by": string,"ended_at"?: string | null,"expires_at": string,"financing_id": string,"id"?: string,"outcome"?: string | null,"pledge_id": string,"tenant_id": string
                  }
                  Update: {
                    "agent_id"?: string,"claimed_at"?: string,"claimed_by"?: string,"ended_at"?: string | null,"expires_at"?: string,"financing_id"?: string,"id"?: string,"outcome"?: string | null,"pledge_id"?: string,"tenant_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_financing_claims_agent_id_fkey"
      columns: ["agent_id"]
isOneToOne: false
      referencedRelation: "monvelo_agents"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_financing_claims_claimed_by_fkey"
      columns: ["claimed_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_financing_claims_tenant_id_financing_id_fkey"
      columns: ["tenant_id","financing_id"]
isOneToOne: false
      referencedRelation: "monvelo_financings"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_financing_claims_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_financing_claims_tenant_id_pledge_id_fkey"
      columns: ["tenant_id","pledge_id"]
isOneToOne: false
      referencedRelation: "monvelo_pledges"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"monvelo_financing_cover": {
                  Row: {
                    "blocks": number,"cover_kind": string,"created_at": string,"declared_status": string,"financing_id": string,"gross_rebate": number,"locked_at": string,"net_rebate": number,"product_id": string | null,"shop_policy_id": string | null,"storage_premium": number,"storage_rate_bps": number,"tenant_id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "blocks": number,"cover_kind": string,"created_at"?: string,"declared_status"?: string,"financing_id": string,"gross_rebate": number,"locked_at": string,"net_rebate": number,"product_id"?: string | null,"shop_policy_id"?: string | null,"storage_premium": number,"storage_rate_bps"?: number,"tenant_id": string,"updated_at"?: string
                  }
                  Update: {
                    "blocks"?: number,"cover_kind"?: string,"created_at"?: string,"declared_status"?: string,"financing_id"?: string,"gross_rebate"?: number,"locked_at"?: string,"net_rebate"?: number,"product_id"?: string | null,"shop_policy_id"?: string | null,"storage_premium"?: number,"storage_rate_bps"?: number,"tenant_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_financing_cover_product_id_fkey"
      columns: ["product_id"]
isOneToOne: false
      referencedRelation: "monvelo_insurance_products"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_financing_cover_shop_policy_id_fkey"
      columns: ["shop_policy_id"]
isOneToOne: false
      referencedRelation: "monvelo_shop_policies"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_financing_cover_tenant_id_financing_id_fkey"
      columns: ["tenant_id","financing_id"]
isOneToOne: false
      referencedRelation: "monvelo_financings"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_financing_cover_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_financing_line_cover": {
                  Row: {
                    "brand_key": string,"created_at": string,"financing_id": string,"gross_rebate": number,"interest_free_days": number,"late_charge_bps": number,"net_rebate": number,"rebate_bps": number,"storage_premium": number,"tenant_id": string,"terms_id": string | null,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "brand_key": string,"created_at"?: string,"financing_id": string,"gross_rebate": number,"interest_free_days": number,"late_charge_bps": number,"net_rebate": number,"rebate_bps": number,"storage_premium": number,"tenant_id": string,"terms_id"?: string | null,"updated_at"?: string
                  }
                  Update: {
                    "brand_key"?: string,"created_at"?: string,"financing_id"?: string,"gross_rebate"?: number,"interest_free_days"?: number,"late_charge_bps"?: number,"net_rebate"?: number,"rebate_bps"?: number,"storage_premium"?: number,"tenant_id"?: string,"terms_id"?: string | null,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_financing_line_cover_financing_id_brand_key_fkey"
      columns: ["financing_id","brand_key"]
isOneToOne: true
      referencedRelation: "monvelo_financing_lines"
      referencedColumns: ["financing_id","brand_key"]
    },{
      foreignKeyName: "monvelo_financing_line_cover_financing_id_fkey"
      columns: ["financing_id"]
isOneToOne: false
      referencedRelation: "monvelo_financing_cover"
      referencedColumns: ["financing_id"]
    },{
      foreignKeyName: "monvelo_financing_line_cover_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_financing_line_cover_tenant_id_terms_id_fkey"
      columns: ["tenant_id","terms_id"]
isOneToOne: false
      referencedRelation: "monvelo_brand_terms"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"monvelo_financing_lines": {
                  Row: {
                    "amount": number,"brand": string,"brand_key": string,"financing_id": string,"interest_free_days": number | null,"late_charge_bps": number | null,"rebate_bps": number | null,"tenant_id": string,"terms_id": string | null,"terms_locked_at": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "amount": number,"brand": string,"brand_key": string,"financing_id": string,"interest_free_days"?: number | null,"late_charge_bps"?: number | null,"rebate_bps"?: number | null,"tenant_id": string,"terms_id"?: string | null,"terms_locked_at"?: string | null
                  }
                  Update: {
                    "amount"?: number,"brand"?: string,"brand_key"?: string,"financing_id"?: string,"interest_free_days"?: number | null,"late_charge_bps"?: number | null,"rebate_bps"?: number | null,"tenant_id"?: string,"terms_id"?: string | null,"terms_locked_at"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_financing_lines_tenant_id_financing_id_fkey"
      columns: ["tenant_id","financing_id"]
isOneToOne: false
      referencedRelation: "monvelo_financings"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_financing_lines_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_financing_lines_tenant_id_terms_id_fkey"
      columns: ["tenant_id","terms_id"]
isOneToOne: false
      referencedRelation: "monvelo_brand_terms"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"monvelo_financings": {
                  Row: {
                    "approval_required": boolean,"approved_at": string | null,"approved_by": string | null,"area_id": string,"cancel_reason": string | null,"cancelled_at": string | null,"cancelled_by": string | null,"claim_expires_at": string | null,"claimed_by": string | null,"claimed_by_agent_id": string | null,"closed_at": string | null,"created_at": string,"delivered_at": string | null,"due_at": string | null,"funded_at": string | null,"funder_agent_id": string | null,"id": string,"late_charge_amount": number,"offered_at": string | null,"order_id": string,"outstanding": number | null,"paystack_reference": string | null,"pledge_id": string | null,"preferred_agent_id": string | null,"preferred_window_ends_at": string | null,"principal": number,"raised_by": string,"reference": string,"shop_id": string,"status": string,"supply_date": string,"tenant_id": string,"territory_id": string,"updated_at": string,"monvelo_apply_late_charge": {
              "approval_required": boolean,
"approved_at": string | null,
"approved_by": string | null,
"area_id": string,
"cancel_reason": string | null,
"cancelled_at": string | null,
"cancelled_by": string | null,
"claim_expires_at": string | null,
"claimed_by": string | null,
"claimed_by_agent_id": string | null,
"closed_at": string | null,
"created_at": string,
"delivered_at": string | null,
"due_at": string | null,
"funded_at": string | null,
"funder_agent_id": string | null,
"id": string,
"late_charge_amount": number,
"offered_at": string | null,
"order_id": string,
"outstanding": number | null,
"paystack_reference": string | null,
"pledge_id": string | null,
"preferred_agent_id": string | null,
"preferred_window_ends_at": string | null,
"principal": number,
"raised_by": string,
"reference": string,
"shop_id": string,
"status": string,
"supply_date": string,
"tenant_id": string,
"territory_id": string,
"updated_at": string
            } | null,"monvelo_apply_late_charge_now": {
              "approval_required": boolean,
"approved_at": string | null,
"approved_by": string | null,
"area_id": string,
"cancel_reason": string | null,
"cancelled_at": string | null,
"cancelled_by": string | null,
"claim_expires_at": string | null,
"claimed_by": string | null,
"claimed_by_agent_id": string | null,
"closed_at": string | null,
"created_at": string,
"delivered_at": string | null,
"due_at": string | null,
"funded_at": string | null,
"funder_agent_id": string | null,
"id": string,
"late_charge_amount": number,
"offered_at": string | null,
"order_id": string,
"outstanding": number | null,
"paystack_reference": string | null,
"pledge_id": string | null,
"preferred_agent_id": string | null,
"preferred_window_ends_at": string | null,
"principal": number,
"raised_by": string,
"reference": string,
"shop_id": string,
"status": string,
"supply_date": string,
"tenant_id": string,
"territory_id": string,
"updated_at": string
            } | null,"monvelo_assert_delivery_day": undefined | null,"monvelo_unpaid_principal": number | null
                  }
                  ComputedFields: "monvelo_apply_late_charge" | "monvelo_apply_late_charge_now" | "monvelo_assert_delivery_day" | "monvelo_unpaid_principal"
                  Insert: {
                    "approval_required": boolean,"approved_at"?: string | null,"approved_by"?: string | null,"area_id": string,"cancel_reason"?: string | null,"cancelled_at"?: string | null,"cancelled_by"?: string | null,"claim_expires_at"?: string | null,"claimed_by"?: string | null,"claimed_by_agent_id"?: string | null,"closed_at"?: string | null,"created_at"?: string,"delivered_at"?: string | null,"due_at"?: string | null,"funded_at"?: string | null,"funder_agent_id"?: string | null,"id"?: string,"late_charge_amount"?: number,"offered_at"?: string | null,"order_id": string,"outstanding"?: number | null,"paystack_reference"?: string | null,"pledge_id"?: string | null,"preferred_agent_id"?: string | null,"preferred_window_ends_at"?: string | null,"principal": number,"raised_by": string,"reference": string,"shop_id": string,"status"?: string,"supply_date": string,"tenant_id": string,"territory_id": string,"updated_at"?: string
                  }
                  Update: {
                    "approval_required"?: boolean,"approved_at"?: string | null,"approved_by"?: string | null,"area_id"?: string,"cancel_reason"?: string | null,"cancelled_at"?: string | null,"cancelled_by"?: string | null,"claim_expires_at"?: string | null,"claimed_by"?: string | null,"claimed_by_agent_id"?: string | null,"closed_at"?: string | null,"created_at"?: string,"delivered_at"?: string | null,"due_at"?: string | null,"funded_at"?: string | null,"funder_agent_id"?: string | null,"id"?: string,"late_charge_amount"?: number,"offered_at"?: string | null,"order_id"?: string,"outstanding"?: number | null,"paystack_reference"?: string | null,"pledge_id"?: string | null,"preferred_agent_id"?: string | null,"preferred_window_ends_at"?: string | null,"principal"?: number,"raised_by"?: string,"reference"?: string,"shop_id"?: string,"status"?: string,"supply_date"?: string,"tenant_id"?: string,"territory_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_financings_approved_by_fkey"
      columns: ["approved_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_financings_cancelled_by_fkey"
      columns: ["cancelled_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_financings_claimed_by_agent_id_fkey"
      columns: ["claimed_by_agent_id"]
isOneToOne: false
      referencedRelation: "monvelo_agents"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_financings_claimed_by_fkey"
      columns: ["claimed_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_financings_funder_agent_id_fkey"
      columns: ["funder_agent_id"]
isOneToOne: false
      referencedRelation: "monvelo_agents"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_financings_preferred_agent_id_fkey"
      columns: ["preferred_agent_id"]
isOneToOne: false
      referencedRelation: "monvelo_agents"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_financings_raised_by_fkey"
      columns: ["raised_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_financings_tenant_id_area_id_fkey"
      columns: ["tenant_id","area_id"]
isOneToOne: false
      referencedRelation: "areas"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_financings_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_financings_tenant_id_order_id_fkey"
      columns: ["tenant_id","order_id"]
isOneToOne: false
      referencedRelation: "orders"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_financings_tenant_id_pledge_id_fkey"
      columns: ["tenant_id","pledge_id"]
isOneToOne: false
      referencedRelation: "monvelo_pledges"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_financings_tenant_id_shop_id_fkey"
      columns: ["tenant_id","shop_id"]
isOneToOne: false
      referencedRelation: "monvelo_shop_enrolments"
      referencedColumns: ["tenant_id","shop_id"]
    },{
      foreignKeyName: "monvelo_financings_tenant_id_territory_id_fkey"
      columns: ["tenant_id","territory_id"]
isOneToOne: false
      referencedRelation: "territories"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"monvelo_flags": {
                  Row: {
                    "agent_id": string | null,"created_at": string,"details": NonNullable<Json>,"financing_id": string | null,"id": string,"kind": string,"review_note": string | null,"reviewed_at": string | null,"reviewed_by": string | null,"status": string
                  }
                  ComputedFields: never
                  Insert: {
                    "agent_id"?: string | null,"created_at"?: string,"details"?: NonNullable<Json>,"financing_id"?: string | null,"id"?: string,"kind": string,"review_note"?: string | null,"reviewed_at"?: string | null,"reviewed_by"?: string | null,"status"?: string
                  }
                  Update: {
                    "agent_id"?: string | null,"created_at"?: string,"details"?: NonNullable<Json>,"financing_id"?: string | null,"id"?: string,"kind"?: string,"review_note"?: string | null,"reviewed_at"?: string | null,"reviewed_by"?: string | null,"status"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_flags_agent_id_fkey"
      columns: ["agent_id"]
isOneToOne: false
      referencedRelation: "monvelo_agents"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_flags_financing_id_fkey"
      columns: ["financing_id"]
isOneToOne: false
      referencedRelation: "monvelo_financings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_flags_reviewed_by_fkey"
      columns: ["reviewed_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_insurance_claims": {
                  Row: {
                    "claimed_amount": number,"closed_reason": string | null,"created_at": string,"description": string | null,"evidence_paths": (string)[],"filed_at": string | null,"filed_by": string | null,"financing_id": string,"id": string,"incident_at": string,"insurer_claim_reference": string | null,"insurer_id": string | null,"kind": string,"late_charge_waived": number | null,"payee_agent_id": string | null,"payee_kind": string,"payout_reference": string | null,"peril": string,"reference": string,"reported_by": string,"settled_amount": number | null,"settled_at": string | null,"shortfall": number | null,"status": string,"tenant_id": string,"updated_at": string,"monvelo_notify_claim": undefined | null
                  }
                  ComputedFields: "monvelo_notify_claim"
                  Insert: {
                    "claimed_amount": number,"closed_reason"?: string | null,"created_at"?: string,"description"?: string | null,"evidence_paths"?: (string)[],"filed_at"?: string | null,"filed_by"?: string | null,"financing_id": string,"id"?: string,"incident_at": string,"insurer_claim_reference"?: string | null,"insurer_id"?: string | null,"kind": string,"late_charge_waived"?: number | null,"payee_agent_id"?: string | null,"payee_kind": string,"payout_reference"?: string | null,"peril": string,"reference": string,"reported_by": string,"settled_amount"?: number | null,"settled_at"?: string | null,"shortfall"?: never,"status"?: string,"tenant_id": string,"updated_at"?: string
                  }
                  Update: {
                    "claimed_amount"?: number,"closed_reason"?: string | null,"created_at"?: string,"description"?: string | null,"evidence_paths"?: (string)[],"filed_at"?: string | null,"filed_by"?: string | null,"financing_id"?: string,"id"?: string,"incident_at"?: string,"insurer_claim_reference"?: string | null,"insurer_id"?: string | null,"kind"?: string,"late_charge_waived"?: number | null,"payee_agent_id"?: string | null,"payee_kind"?: string,"payout_reference"?: string | null,"peril"?: string,"reference"?: string,"reported_by"?: string,"settled_amount"?: number | null,"settled_at"?: string | null,"shortfall"?: never,"status"?: string,"tenant_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_insurance_claims_filed_by_fkey"
      columns: ["filed_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_insurance_claims_insurer_id_fkey"
      columns: ["insurer_id"]
isOneToOne: false
      referencedRelation: "monvelo_insurers"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_insurance_claims_payee_agent_id_fkey"
      columns: ["payee_agent_id"]
isOneToOne: false
      referencedRelation: "monvelo_agents"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_insurance_claims_reported_by_fkey"
      columns: ["reported_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_insurance_claims_tenant_id_financing_id_fkey"
      columns: ["tenant_id","financing_id"]
isOneToOne: false
      referencedRelation: "monvelo_financings"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_insurance_claims_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_insurance_declarations": {
                  Row: {
                    "attempts": number,"completed_at": string | null,"created_at": string,"id": string,"insurer_id": string,"insurer_reference": string | null,"kind": string,"last_error": string | null,"next_attempt_at": string,"payload": NonNullable<Json>,"status": string,"subject_id": string,"subject_table": string,"tenant_id": string,"updated_at": string,"monvelo_declaration_financing": string | null
                  }
                  ComputedFields: "monvelo_declaration_financing"
                  Insert: {
                    "attempts"?: number,"completed_at"?: string | null,"created_at"?: string,"id"?: string,"insurer_id": string,"insurer_reference"?: string | null,"kind": string,"last_error"?: string | null,"next_attempt_at"?: string,"payload": NonNullable<Json>,"status"?: string,"subject_id": string,"subject_table": string,"tenant_id": string,"updated_at"?: string
                  }
                  Update: {
                    "attempts"?: number,"completed_at"?: string | null,"created_at"?: string,"id"?: string,"insurer_id"?: string,"insurer_reference"?: string | null,"kind"?: string,"last_error"?: string | null,"next_attempt_at"?: string,"payload"?: NonNullable<Json>,"status"?: string,"subject_id"?: string,"subject_table"?: string,"tenant_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_insurance_declarations_insurer_id_fkey"
      columns: ["insurer_id"]
isOneToOne: false
      referencedRelation: "monvelo_insurers"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_insurance_declarations_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_insurance_products": {
                  Row: {
                    "approved_at": string | null,"approved_by": string | null,"created_at": string,"facilitator_fee_bps": number,"id": string,"insurer_id": string,"kind": string,"proposed_by": string,"rate_bps": number,"status": string,"updated_at": string,"valid_from": string,"valid_to": string | null,"withdraw_reason": string | null,"withdrawn_at": string | null,"withdrawn_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "approved_at"?: string | null,"approved_by"?: string | null,"created_at"?: string,"facilitator_fee_bps": number,"id"?: string,"insurer_id": string,"kind": string,"proposed_by": string,"rate_bps": number,"status"?: string,"updated_at"?: string,"valid_from": string,"valid_to"?: string | null,"withdraw_reason"?: string | null,"withdrawn_at"?: string | null,"withdrawn_by"?: string | null
                  }
                  Update: {
                    "approved_at"?: string | null,"approved_by"?: string | null,"created_at"?: string,"facilitator_fee_bps"?: number,"id"?: string,"insurer_id"?: string,"kind"?: string,"proposed_by"?: string,"rate_bps"?: number,"status"?: string,"updated_at"?: string,"valid_from"?: string,"valid_to"?: string | null,"withdraw_reason"?: string | null,"withdrawn_at"?: string | null,"withdrawn_by"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_insurance_products_approved_by_fkey"
      columns: ["approved_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_insurance_products_insurer_id_fkey"
      columns: ["insurer_id"]
isOneToOne: false
      referencedRelation: "monvelo_insurers"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_insurance_products_proposed_by_fkey"
      columns: ["proposed_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_insurance_products_withdrawn_by_fkey"
      columns: ["withdrawn_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_insurer_events": {
                  Row: {
                    "event_id": string,"insurer_id": string,"payload": NonNullable<Json>,"received_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "event_id": string,"insurer_id": string,"payload": NonNullable<Json>,"received_at"?: string
                  }
                  Update: {
                    "event_id"?: string,"insurer_id"?: string,"payload"?: NonNullable<Json>,"received_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_insurer_events_insurer_id_fkey"
      columns: ["insurer_id"]
isOneToOne: false
      referencedRelation: "monvelo_insurers"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_insurers": {
                  Row: {
                    "api_provider": string,"code": string,"created_at": string,"created_by": string,"id": string,"legal_name": string,"naicom_licence_no": string,"status": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "api_provider": string,"code": string,"created_at"?: string,"created_by": string,"id"?: string,"legal_name": string,"naicom_licence_no": string,"status"?: string,"updated_at"?: string
                  }
                  Update: {
                    "api_provider"?: string,"code"?: string,"created_at"?: string,"created_by"?: string,"id"?: string,"legal_name"?: string,"naicom_licence_no"?: string,"status"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_insurers_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_order_git_cover": {
                  Row: {
                    "created_at": string,"declared_status": string,"financing_id": string,"insured_value": number,"order_id": string,"premium": number,"product_id": string,"rate_bps": number,"tenant_id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"declared_status"?: string,"financing_id": string,"insured_value": number,"order_id": string,"premium": number,"product_id": string,"rate_bps": number,"tenant_id": string,"updated_at"?: string
                  }
                  Update: {
                    "created_at"?: string,"declared_status"?: string,"financing_id"?: string,"insured_value"?: number,"order_id"?: string,"premium"?: number,"product_id"?: string,"rate_bps"?: number,"tenant_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_order_git_cover_product_id_fkey"
      columns: ["product_id"]
isOneToOne: false
      referencedRelation: "monvelo_insurance_products"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_order_git_cover_tenant_id_financing_id_fkey"
      columns: ["tenant_id","financing_id"]
isOneToOne: false
      referencedRelation: "monvelo_financings"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_order_git_cover_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_order_git_cover_tenant_id_order_id_fkey"
      columns: ["tenant_id","order_id"]
isOneToOne: false
      referencedRelation: "orders"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"monvelo_owner_challenges": {
                  Row: {
                    "code_hash": string,"consumed_at": string | null,"created_at": string,"expires_at": string,"failed_attempts": number,"financing_id": string,"id": string,"issued_by": string,"purpose": string,"repayment_id": string | null,"tenant_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "code_hash": string,"consumed_at"?: string | null,"created_at"?: string,"expires_at": string,"failed_attempts"?: number,"financing_id": string,"id"?: string,"issued_by": string,"purpose": string,"repayment_id"?: string | null,"tenant_id": string
                  }
                  Update: {
                    "code_hash"?: string,"consumed_at"?: string | null,"created_at"?: string,"expires_at"?: string,"failed_attempts"?: number,"financing_id"?: string,"id"?: string,"issued_by"?: string,"purpose"?: string,"repayment_id"?: string | null,"tenant_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_owner_challenges_issued_by_fkey"
      columns: ["issued_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_owner_challenges_repayment_fk"
      columns: ["tenant_id","repayment_id"]
isOneToOne: false
      referencedRelation: "monvelo_repayments"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_owner_challenges_tenant_id_financing_id_fkey"
      columns: ["tenant_id","financing_id"]
isOneToOne: false
      referencedRelation: "monvelo_financings"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_owner_challenges_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_platform_settings": {
                  Row: {
                    "allow_mock_insurers": boolean,"claim_minutes": number,"id": boolean,"offer_radius_m": number,"order_cutoff_local": string,"preferred_window_minutes": number,"supply_lead_days": number,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "allow_mock_insurers"?: boolean,"claim_minutes"?: number,"id"?: boolean,"offer_radius_m"?: number,"order_cutoff_local"?: string,"preferred_window_minutes"?: number,"supply_lead_days"?: number,"updated_at"?: string
                  }
                  Update: {
                    "allow_mock_insurers"?: boolean,"claim_minutes"?: number,"id"?: boolean,"offer_radius_m"?: number,"order_cutoff_local"?: string,"preferred_window_minutes"?: number,"supply_lead_days"?: number,"updated_at"?: string
                  }
                  Relationships: [
                    
                  ]
                },"monvelo_pledges": {
                  Row: {
                    "agent_id": string,"amount": number,"area_id": string,"created_at": string,"id": string,"pledged_by": string,"remaining": number,"supply_date": string,"tenant_id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "agent_id": string,"amount": number,"area_id": string,"created_at"?: string,"id"?: string,"pledged_by": string,"remaining": number,"supply_date": string,"tenant_id": string,"updated_at"?: string
                  }
                  Update: {
                    "agent_id"?: string,"amount"?: number,"area_id"?: string,"created_at"?: string,"id"?: string,"pledged_by"?: string,"remaining"?: number,"supply_date"?: string,"tenant_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_pledges_agent_id_fkey"
      columns: ["agent_id"]
isOneToOne: false
      referencedRelation: "monvelo_agents"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_pledges_pledged_by_fkey"
      columns: ["pledged_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_pledges_tenant_id_area_id_fkey"
      columns: ["tenant_id","area_id"]
isOneToOne: false
      referencedRelation: "areas"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_pledges_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_premium_payables": {
                  Row: {
                    "amount": number,"created_at": string,"due_at": string,"financing_id": string,"id": string,"insurer_id": string,"kind": string,"paid_at": string | null,"paid_by": string | null,"paid_reference": string | null,"status": string,"tenant_id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "amount": number,"created_at"?: string,"due_at": string,"financing_id": string,"id"?: string,"insurer_id": string,"kind": string,"paid_at"?: string | null,"paid_by"?: string | null,"paid_reference"?: string | null,"status"?: string,"tenant_id": string,"updated_at"?: string
                  }
                  Update: {
                    "amount"?: number,"created_at"?: string,"due_at"?: string,"financing_id"?: string,"id"?: string,"insurer_id"?: string,"kind"?: string,"paid_at"?: string | null,"paid_by"?: string | null,"paid_reference"?: string | null,"status"?: string,"tenant_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_premium_payables_insurer_id_fkey"
      columns: ["insurer_id"]
isOneToOne: false
      referencedRelation: "monvelo_insurers"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_premium_payables_paid_by_fkey"
      columns: ["paid_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_premium_payables_tenant_id_financing_id_fkey"
      columns: ["tenant_id","financing_id"]
isOneToOne: false
      referencedRelation: "monvelo_financings"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_premium_payables_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_rebate_payable_lines": {
                  Row: {
                    "amount": number,"brand_key": string,"payable_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "amount": number,"brand_key": string,"payable_id": string
                  }
                  Update: {
                    "amount"?: number,"brand_key"?: string,"payable_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_rebate_payable_lines_payable_id_fkey"
      columns: ["payable_id"]
isOneToOne: false
      referencedRelation: "monvelo_rebate_payables"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_rebate_payables": {
                  Row: {
                    "agent_id": string,"amount": number,"created_at": string,"due_at": string,"financing_id": string,"id": string,"status": string,"tenant_id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "agent_id": string,"amount": number,"created_at"?: string,"due_at": string,"financing_id": string,"id"?: string,"status"?: string,"tenant_id": string,"updated_at"?: string
                  }
                  Update: {
                    "agent_id"?: string,"amount"?: number,"created_at"?: string,"due_at"?: string,"financing_id"?: string,"id"?: string,"status"?: string,"tenant_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_rebate_payables_agent_id_fkey"
      columns: ["agent_id"]
isOneToOne: false
      referencedRelation: "monvelo_agents"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_rebate_payables_tenant_id_financing_id_fkey"
      columns: ["tenant_id","financing_id"]
isOneToOne: false
      referencedRelation: "monvelo_financings"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_rebate_payables_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_rebate_topups": {
                  Row: {
                    "agent_id": string,"amount": number,"created_at": string,"due_at": string,"financing_id": string,"id": string,"paid_at": string | null,"paid_by": string | null,"paid_reference": string | null,"reason": string,"status": string,"tenant_id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "agent_id": string,"amount": number,"created_at"?: string,"due_at": string,"financing_id": string,"id"?: string,"paid_at"?: string | null,"paid_by"?: string | null,"paid_reference"?: string | null,"reason": string,"status"?: string,"tenant_id": string,"updated_at"?: string
                  }
                  Update: {
                    "agent_id"?: string,"amount"?: number,"created_at"?: string,"due_at"?: string,"financing_id"?: string,"id"?: string,"paid_at"?: string | null,"paid_by"?: string | null,"paid_reference"?: string | null,"reason"?: string,"status"?: string,"tenant_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_rebate_topups_agent_id_fkey"
      columns: ["agent_id"]
isOneToOne: false
      referencedRelation: "monvelo_agents"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_rebate_topups_paid_by_fkey"
      columns: ["paid_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_rebate_topups_tenant_id_financing_id_fkey"
      columns: ["tenant_id","financing_id"]
isOneToOne: false
      referencedRelation: "monvelo_financings"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_rebate_topups_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_repayments": {
                  Row: {
                    "amount": number,"challenge_id": string,"confirmed_at": string | null,"ended_at": string | null,"financing_id": string,"id": string,"recorded_at": string,"recorded_by": string,"status": string,"tenant_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "amount": number,"challenge_id": string,"confirmed_at"?: string | null,"ended_at"?: string | null,"financing_id": string,"id"?: string,"recorded_at"?: string,"recorded_by": string,"status"?: string,"tenant_id": string
                  }
                  Update: {
                    "amount"?: number,"challenge_id"?: string,"confirmed_at"?: string | null,"ended_at"?: string | null,"financing_id"?: string,"id"?: string,"recorded_at"?: string,"recorded_by"?: string,"status"?: string,"tenant_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_repayments_challenge_fk"
      columns: ["tenant_id","challenge_id"]
isOneToOne: false
      referencedRelation: "monvelo_owner_challenges"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_repayments_recorded_by_fkey"
      columns: ["recorded_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_repayments_tenant_id_financing_id_fkey"
      columns: ["tenant_id","financing_id"]
isOneToOne: false
      referencedRelation: "monvelo_financings"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_repayments_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_shop_enrolments": {
                  Row: {
                    "area_id": string,"consent_at": string,"consent_challenge_id": string,"consent_version": string,"created_at": string,"recruited_by": string,"shop_id": string,"status": string,"tenant_id": string,"withdrawn_at": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "area_id": string,"consent_at": string,"consent_challenge_id": string,"consent_version": string,"created_at"?: string,"recruited_by": string,"shop_id": string,"status"?: string,"tenant_id": string,"withdrawn_at"?: string | null
                  }
                  Update: {
                    "area_id"?: string,"consent_at"?: string,"consent_challenge_id"?: string,"consent_version"?: string,"created_at"?: string,"recruited_by"?: string,"shop_id"?: string,"status"?: string,"tenant_id"?: string,"withdrawn_at"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_shop_enrolments_consent_challenge_id_fkey"
      columns: ["consent_challenge_id"]
isOneToOne: false
      referencedRelation: "monvelo_consent_challenges"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_shop_enrolments_recruited_by_fkey"
      columns: ["recruited_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_shop_enrolments_shop_id_fkey"
      columns: ["shop_id"]
isOneToOne: false
      referencedRelation: "retail_shops"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_shop_enrolments_tenant_id_area_id_fkey"
      columns: ["tenant_id","area_id"]
isOneToOne: false
      referencedRelation: "areas"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_shop_enrolments_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_shop_limit_events": {
                  Row: {
                    "brand_key": string,"created_at": string,"financing_id": string | null,"id": string,"kind": string,"new_limit": number,"old_limit": number | null,"shop_id": string,"tenant_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "brand_key": string,"created_at"?: string,"financing_id"?: string | null,"id"?: string,"kind": string,"new_limit": number,"old_limit"?: number | null,"shop_id": string,"tenant_id": string
                  }
                  Update: {
                    "brand_key"?: string,"created_at"?: string,"financing_id"?: string | null,"id"?: string,"kind"?: string,"new_limit"?: number,"old_limit"?: number | null,"shop_id"?: string,"tenant_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_shop_limit_events_tenant_id_financing_id_fkey"
      columns: ["tenant_id","financing_id"]
isOneToOne: false
      referencedRelation: "monvelo_financings"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_shop_limit_events_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_shop_limit_events_tenant_id_shop_id_brand_key_fkey"
      columns: ["tenant_id","shop_id","brand_key"]
isOneToOne: false
      referencedRelation: "monvelo_shop_limits"
      referencedColumns: ["tenant_id","shop_id","brand_key"]
    }
                  ]
                },"monvelo_shop_limits": {
                  Row: {
                    "brand_key": string,"created_at": string,"limit_amount": number,"shop_id": string,"status": string,"tenant_id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "brand_key": string,"created_at"?: string,"limit_amount": number,"shop_id": string,"status"?: string,"tenant_id": string,"updated_at"?: string
                  }
                  Update: {
                    "brand_key"?: string,"created_at"?: string,"limit_amount"?: number,"shop_id"?: string,"status"?: string,"tenant_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_shop_limits_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_shop_limits_tenant_id_shop_id_fkey"
      columns: ["tenant_id","shop_id"]
isOneToOne: false
      referencedRelation: "monvelo_shop_enrolments"
      referencedColumns: ["tenant_id","shop_id"]
    }
                  ]
                },"monvelo_shop_pairings": {
                  Row: {
                    "agent_id": string,"area_id": string,"id": string,"paired_at": string,"paired_by": string,"shop_id": string,"source": string,"tenant_id": string,"unpair_reason": string | null,"unpaired_at": string | null,"unpaired_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "agent_id": string,"area_id": string,"id"?: string,"paired_at"?: string,"paired_by": string,"shop_id": string,"source": string,"tenant_id": string,"unpair_reason"?: string | null,"unpaired_at"?: string | null,"unpaired_by"?: string | null
                  }
                  Update: {
                    "agent_id"?: string,"area_id"?: string,"id"?: string,"paired_at"?: string,"paired_by"?: string,"shop_id"?: string,"source"?: string,"tenant_id"?: string,"unpair_reason"?: string | null,"unpaired_at"?: string | null,"unpaired_by"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_shop_pairings_agent_id_fkey"
      columns: ["agent_id"]
isOneToOne: false
      referencedRelation: "monvelo_agents"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_shop_pairings_paired_by_fkey"
      columns: ["paired_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_shop_pairings_shop_id_fkey"
      columns: ["shop_id"]
isOneToOne: false
      referencedRelation: "retail_shops"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_shop_pairings_tenant_id_area_id_fkey"
      columns: ["tenant_id","area_id"]
isOneToOne: false
      referencedRelation: "areas"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_shop_pairings_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_shop_pairings_tenant_id_shop_id_fkey"
      columns: ["tenant_id","shop_id"]
isOneToOne: false
      referencedRelation: "monvelo_shop_enrolments"
      referencedColumns: ["tenant_id","shop_id"]
    },{
      foreignKeyName: "monvelo_shop_pairings_unpaired_by_fkey"
      columns: ["unpaired_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_shop_policies": {
                  Row: {
                    "consent_challenge_id": string,"covers_burglary": boolean,"covers_fire_perils": boolean,"created_at": string,"document_path": string,"expires_on": string,"expiry_notice_sent_at": string | null,"id": string,"insurer_name": string,"lender_interest_endorsed": boolean,"policy_number": string,"review_note": string | null,"reviewed_at": string | null,"reviewed_by": string | null,"shop_id": string,"starts_on": string,"status": string,"submitted_by": string,"sum_insured": number,"updated_at": string,"withdraw_reason": string | null,"withdrawn_at": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "consent_challenge_id": string,"covers_burglary": boolean,"covers_fire_perils": boolean,"created_at"?: string,"document_path": string,"expires_on": string,"expiry_notice_sent_at"?: string | null,"id"?: string,"insurer_name": string,"lender_interest_endorsed": boolean,"policy_number": string,"review_note"?: string | null,"reviewed_at"?: string | null,"reviewed_by"?: string | null,"shop_id": string,"starts_on": string,"status"?: string,"submitted_by": string,"sum_insured": number,"updated_at"?: string,"withdraw_reason"?: string | null,"withdrawn_at"?: string | null
                  }
                  Update: {
                    "consent_challenge_id"?: string,"covers_burglary"?: boolean,"covers_fire_perils"?: boolean,"created_at"?: string,"document_path"?: string,"expires_on"?: string,"expiry_notice_sent_at"?: string | null,"id"?: string,"insurer_name"?: string,"lender_interest_endorsed"?: boolean,"policy_number"?: string,"review_note"?: string | null,"reviewed_at"?: string | null,"reviewed_by"?: string | null,"shop_id"?: string,"starts_on"?: string,"status"?: string,"submitted_by"?: string,"sum_insured"?: number,"updated_at"?: string,"withdraw_reason"?: string | null,"withdrawn_at"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_shop_policies_consent_challenge_id_fkey"
      columns: ["consent_challenge_id"]
isOneToOne: false
      referencedRelation: "monvelo_consent_challenges"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_shop_policies_reviewed_by_fkey"
      columns: ["reviewed_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_shop_policies_shop_id_fkey"
      columns: ["shop_id"]
isOneToOne: false
      referencedRelation: "retail_shops"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_shop_policies_submitted_by_fkey"
      columns: ["submitted_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_supply_days": {
                  Row: {
                    "active": boolean,"area_id": string,"created_at": string,"day_of_week": number,"set_by": string,"tenant_id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "active"?: boolean,"area_id": string,"created_at"?: string,"day_of_week": number,"set_by": string,"tenant_id": string,"updated_at"?: string
                  }
                  Update: {
                    "active"?: boolean,"area_id"?: string,"created_at"?: string,"day_of_week"?: number,"set_by"?: string,"tenant_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_supply_days_set_by_fkey"
      columns: ["set_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_supply_days_tenant_id_area_id_fkey"
      columns: ["tenant_id","area_id"]
isOneToOne: false
      referencedRelation: "areas"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_supply_days_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_tenant_fee_terms": {
                  Row: {
                    "created_at": string,"decision_id": string | null,"fee_bps": number,"id": string,"recorded_by": string,"tenant_id": string,"valid_from": string,"valid_to": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"decision_id"?: string | null,"fee_bps": number,"id"?: string,"recorded_by": string,"tenant_id": string,"valid_from": string,"valid_to"?: string | null
                  }
                  Update: {
                    "created_at"?: string,"decision_id"?: string | null,"fee_bps"?: number,"id"?: string,"recorded_by"?: string,"tenant_id"?: string,"valid_from"?: string,"valid_to"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_tenant_fee_terms_decision_fkey"
      columns: ["tenant_id","decision_id"]
isOneToOne: false
      referencedRelation: "contact_report_decisions"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_tenant_fee_terms_recorded_by_fkey"
      columns: ["recorded_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_tenant_fee_terms_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_tenant_ledger_entries": {
                  Row: {
                    "amount": number,"business_date": string,"created_at": string,"entry_type": string,"financing_id": string | null,"id": string,"tenant_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "amount": number,"business_date": string,"created_at"?: string,"entry_type": string,"financing_id"?: string | null,"id"?: string,"tenant_id": string
                  }
                  Update: {
                    "amount"?: number,"business_date"?: string,"created_at"?: string,"entry_type"?: string,"financing_id"?: string | null,"id"?: string,"tenant_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_tenant_ledger_entries_tenant_id_financing_id_fkey"
      columns: ["tenant_id","financing_id"]
isOneToOne: false
      referencedRelation: "monvelo_financings"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_tenant_ledger_entries_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_tenant_settings": {
                  Row: {
                    "approval_cap": number,"decision_id": string | null,"default_cure_days": number,"enabled": boolean,"git_cover_enabled": boolean,"limit_growth_bps": number,"max_limit": number | null,"opening_limit": number,"post_default_limit_bps": number,"tenant_id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "approval_cap"?: number,"decision_id"?: string | null,"default_cure_days"?: number,"enabled"?: boolean,"git_cover_enabled"?: boolean,"limit_growth_bps"?: number,"max_limit"?: number | null,"opening_limit"?: number,"post_default_limit_bps"?: number,"tenant_id": string,"updated_at"?: string
                  }
                  Update: {
                    "approval_cap"?: number,"decision_id"?: string | null,"default_cure_days"?: number,"enabled"?: boolean,"git_cover_enabled"?: boolean,"limit_growth_bps"?: number,"max_limit"?: number | null,"opening_limit"?: number,"post_default_limit_bps"?: number,"tenant_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_tenant_settings_decision_fkey"
      columns: ["tenant_id","decision_id"]
isOneToOne: false
      referencedRelation: "contact_report_decisions"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "monvelo_tenant_settings_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: true
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"monvelo_terms_acceptances": {
                  Row: {
                    "accepted_at": string,"accepted_by": string,"agent_id": string | null,"audience": string,"body_sha256": string,"decision_id": string | null,"id": string,"tenant_id": string | null,"terms_code": string
                  }
                  ComputedFields: never
                  Insert: {
                    "accepted_at"?: string,"accepted_by": string,"agent_id"?: string | null,"audience": string,"body_sha256": string,"decision_id"?: string | null,"id"?: string,"tenant_id"?: string | null,"terms_code": string
                  }
                  Update: {
                    "accepted_at"?: string,"accepted_by"?: string,"agent_id"?: string | null,"audience"?: string,"body_sha256"?: string,"decision_id"?: string | null,"id"?: string,"tenant_id"?: string | null,"terms_code"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "monvelo_terms_acceptances_accepted_by_fkey"
      columns: ["accepted_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_terms_acceptances_agent_id_fkey"
      columns: ["agent_id"]
isOneToOne: false
      referencedRelation: "monvelo_agents"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_terms_acceptances_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "monvelo_terms_acceptances_terms_code_fkey"
      columns: ["terms_code"]
isOneToOne: false
      referencedRelation: "monvelo_terms_versions"
      referencedColumns: ["code"]
    }
                  ]
                },"monvelo_terms_versions": {
                  Row: {
                    "audience": string,"body": string,"code": string,"created_at": string,"published_at": string | null,"retired_at": string | null,"status": string,"title": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "audience": string,"body": string,"code": string,"created_at"?: string,"published_at"?: string | null,"retired_at"?: string | null,"status"?: string,"title": string,"updated_at"?: string
                  }
                  Update: {
                    "audience"?: string,"body"?: string,"code"?: string,"created_at"?: string,"published_at"?: string | null,"retired_at"?: string | null,"status"?: string,"title"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    
                  ]
                },"ng_lgas": {
                  Row: {
                    "id": string,"name": string,"state_code": string
                  }
                  ComputedFields: never
                  Insert: {
                    "id": string,"name": string,"state_code": string
                  }
                  Update: {
                    "id"?: string,"name"?: string,"state_code"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "ng_lgas_state_code_fkey"
      columns: ["state_code"]
isOneToOne: false
      referencedRelation: "ng_states"
      referencedColumns: ["code"]
    }
                  ]
                },"ng_states": {
                  Row: {
                    "code": string,"name": string
                  }
                  ComputedFields: never
                  Insert: {
                    "code": string,"name": string
                  }
                  Update: {
                    "code"?: string,"name"?: string
                  }
                  Relationships: [
                    
                  ]
                },"notification_logs": {
                  Row: {
                    "channel": string,"created_at": string,"id": string,"phone_last4": string,"purpose": string,"related_id": string | null,"status": string,"tenant_id": string | null,"whatsapp_error": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "channel": string,"created_at"?: string,"id"?: string,"phone_last4": string,"purpose": string,"related_id"?: string | null,"status": string,"tenant_id"?: string | null,"whatsapp_error"?: string | null
                  }
                  Update: {
                    "channel"?: string,"created_at"?: string,"id"?: string,"phone_last4"?: string,"purpose"?: string,"related_id"?: string | null,"status"?: string,"tenant_id"?: string | null,"whatsapp_error"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "notification_logs_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"notifications": {
                  Row: {
                    "body": string | null,"created_at": string,"id": string,"kind": string,"payload": NonNullable<Json>,"read_at": string | null,"tenant_id": string | null,"title": string,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "body"?: string | null,"created_at"?: string,"id"?: string,"kind": string,"payload"?: NonNullable<Json>,"read_at"?: string | null,"tenant_id"?: string | null,"title": string,"user_id": string
                  }
                  Update: {
                    "body"?: string | null,"created_at"?: string,"id"?: string,"kind"?: string,"payload"?: NonNullable<Json>,"read_at"?: string | null,"tenant_id"?: string | null,"title"?: string,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "notifications_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "notifications_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"operational_state_events": {
                  Row: {
                    "app_enabled": boolean,"changed_at": string,"changed_by": string,"id": string,"reason": string,"state_code": string,"web_enabled": boolean
                  }
                  ComputedFields: never
                  Insert: {
                    "app_enabled": boolean,"changed_at"?: string,"changed_by": string,"id"?: string,"reason": string,"state_code": string,"web_enabled": boolean
                  }
                  Update: {
                    "app_enabled"?: boolean,"changed_at"?: string,"changed_by"?: string,"id"?: string,"reason"?: string,"state_code"?: string,"web_enabled"?: boolean
                  }
                  Relationships: [
                    {
      foreignKeyName: "operational_state_events_changed_by_fkey"
      columns: ["changed_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "operational_state_events_state_code_fkey"
      columns: ["state_code"]
isOneToOne: false
      referencedRelation: "ng_states"
      referencedColumns: ["code"]
    }
                  ]
                },"operational_states": {
                  Row: {
                    "app_enabled": boolean,"state_code": string,"updated_at": string,"updated_by": string | null,"web_enabled": boolean
                  }
                  ComputedFields: never
                  Insert: {
                    "app_enabled"?: boolean,"state_code": string,"updated_at"?: string,"updated_by"?: string | null,"web_enabled"?: boolean
                  }
                  Update: {
                    "app_enabled"?: boolean,"state_code"?: string,"updated_at"?: string,"updated_by"?: string | null,"web_enabled"?: boolean
                  }
                  Relationships: [
                    {
      foreignKeyName: "operational_states_state_code_fkey"
      columns: ["state_code"]
isOneToOne: true
      referencedRelation: "ng_states"
      referencedColumns: ["code"]
    },{
      foreignKeyName: "operational_states_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"order_contacts": {
                  Row: {
                    "consent_ip": unknown,"created_at": string,"customer_email": string | null,"customer_name": string | null,"customer_phone": string | null,"delivery_address": string | null,"order_id": string,"phone_verified_at": string | null,"phone_verified_channel": string | null,"tenant_id": string,"territory_id": string | null,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "consent_ip"?: unknown,"created_at"?: string,"customer_email"?: string | null,"customer_name"?: string | null,"customer_phone"?: string | null,"delivery_address"?: string | null,"order_id": string,"phone_verified_at"?: string | null,"phone_verified_channel"?: string | null,"tenant_id": string,"territory_id"?: string | null,"updated_at"?: string
                  }
                  Update: {
                    "consent_ip"?: unknown,"created_at"?: string,"customer_email"?: string | null,"customer_name"?: string | null,"customer_phone"?: string | null,"delivery_address"?: string | null,"order_id"?: string,"phone_verified_at"?: string | null,"phone_verified_channel"?: string | null,"tenant_id"?: string,"territory_id"?: string | null,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "order_contacts_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "order_contacts_tenant_id_order_id_fkey"
      columns: ["tenant_id","order_id"]
isOneToOne: false
      referencedRelation: "orders"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "order_contacts_tenant_id_territory_id_fkey"
      columns: ["tenant_id","territory_id"]
isOneToOne: false
      referencedRelation: "territories"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"order_fulfilments": {
                  Row: {
                    "created_at": string,"damage_claim_deadline": string | null,"delivered_at": string | null,"delivered_by": string | null,"delivered_via": string | null,"delivery_photo_path": string | null,"delivery_pin_hash": string,"dispatched_at": string,"dispatched_by": string,"order_id": string,"pin_failed_attempts": number,"pin_lifetime_failures": number,"pin_locked_until": string | null,"pin_resend_day": string | null,"pin_resend_pending": boolean,"pin_resends_today": number,"pin_sent_at": string | null,"pin_zsm_lock": boolean,"tenant_id": string,"tracking_reference": string | null,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"damage_claim_deadline"?: string | null,"delivered_at"?: string | null,"delivered_by"?: string | null,"delivered_via"?: string | null,"delivery_photo_path"?: string | null,"delivery_pin_hash": string,"dispatched_at"?: string,"dispatched_by": string,"order_id": string,"pin_failed_attempts"?: number,"pin_lifetime_failures"?: number,"pin_locked_until"?: string | null,"pin_resend_day"?: string | null,"pin_resend_pending"?: boolean,"pin_resends_today"?: number,"pin_sent_at"?: string | null,"pin_zsm_lock"?: boolean,"tenant_id": string,"tracking_reference"?: string | null,"updated_at"?: string
                  }
                  Update: {
                    "created_at"?: string,"damage_claim_deadline"?: string | null,"delivered_at"?: string | null,"delivered_by"?: string | null,"delivered_via"?: string | null,"delivery_photo_path"?: string | null,"delivery_pin_hash"?: string,"dispatched_at"?: string,"dispatched_by"?: string,"order_id"?: string,"pin_failed_attempts"?: number,"pin_lifetime_failures"?: number,"pin_locked_until"?: string | null,"pin_resend_day"?: string | null,"pin_resend_pending"?: boolean,"pin_resends_today"?: number,"pin_sent_at"?: string | null,"pin_zsm_lock"?: boolean,"tenant_id"?: string,"tracking_reference"?: string | null,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "order_fulfilments_delivered_by_fkey"
      columns: ["delivered_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "order_fulfilments_dispatched_by_fkey"
      columns: ["dispatched_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "order_fulfilments_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "order_fulfilments_tenant_id_order_id_fkey"
      columns: ["tenant_id","order_id"]
isOneToOne: false
      referencedRelation: "orders"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"order_items": {
                  Row: {
                    "id": string,"line_total": number | null,"order_id": string,"qty": number,"sku_code": string,"tenant_id": string,"unit_price": number
                  }
                  ComputedFields: never
                  Insert: {
                    "id"?: string,"line_total"?: never,"order_id": string,"qty": number,"sku_code": string,"tenant_id": string,"unit_price": number
                  }
                  Update: {
                    "id"?: string,"line_total"?: never,"order_id"?: string,"qty"?: number,"sku_code"?: string,"tenant_id"?: string,"unit_price"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "order_items_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "order_items_tenant_id_order_id_fkey"
      columns: ["tenant_id","order_id"]
isOneToOne: false
      referencedRelation: "orders"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "order_items_tenant_id_sku_code_fkey"
      columns: ["tenant_id","sku_code"]
isOneToOne: false
      referencedRelation: "central_products"
      referencedColumns: ["tenant_id","sku_code"]
    }
                  ]
                },"orders": {
                  Row: {
                    "agent_id": string | null,"attributed_agent_id": string | null,"attributed_venue_id": string | null,"channel": Database["public"]['Enums']["order_channel_enum"],"created_at": string,"delivery_lga_id": string | null,"discount_amount": number,"fulfilment_warehouse_id": string | null,"id": string,"payment_route": string | null,"policy_accepted_at": string | null,"policy_version_tag": string | null,"public_reference": string | null,"referral_code_id": string | null,"retail_shop_id": string | null,"status": string,"teafair_agent_id": string,"tenant_id": string,"territory_id": string | null,"total_amount": number,"tracking_reference": string | null,"transport_fare": number,"updated_at": string,"utm_campaign": string | null,"utm_medium": string | null,"utm_source": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "agent_id"?: string | null,"attributed_agent_id"?: string | null,"attributed_venue_id"?: string | null,"channel": Database["public"]['Enums']["order_channel_enum"],"created_at"?: string,"delivery_lga_id"?: string | null,"discount_amount"?: number,"fulfilment_warehouse_id"?: string | null,"id"?: string,"payment_route"?: string | null,"policy_accepted_at"?: string | null,"policy_version_tag"?: string | null,"public_reference"?: string | null,"referral_code_id"?: string | null,"retail_shop_id"?: string | null,"status"?: string,"teafair_agent_id": string,"tenant_id": string,"territory_id"?: string | null,"total_amount": number,"tracking_reference"?: string | null,"transport_fare"?: number,"updated_at"?: string,"utm_campaign"?: string | null,"utm_medium"?: string | null,"utm_source"?: string | null
                  }
                  Update: {
                    "agent_id"?: string | null,"attributed_agent_id"?: string | null,"attributed_venue_id"?: string | null,"channel"?: Database["public"]['Enums']["order_channel_enum"],"created_at"?: string,"delivery_lga_id"?: string | null,"discount_amount"?: number,"fulfilment_warehouse_id"?: string | null,"id"?: string,"payment_route"?: string | null,"policy_accepted_at"?: string | null,"policy_version_tag"?: string | null,"public_reference"?: string | null,"referral_code_id"?: string | null,"retail_shop_id"?: string | null,"status"?: string,"teafair_agent_id"?: string,"tenant_id"?: string,"territory_id"?: string | null,"total_amount"?: number,"tracking_reference"?: string | null,"transport_fare"?: number,"updated_at"?: string,"utm_campaign"?: string | null,"utm_medium"?: string | null,"utm_source"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "orders_agent_id_fkey"
      columns: ["agent_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "orders_attributed_agent_id_fkey"
      columns: ["attributed_agent_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "orders_attributed_venue_fk"
      columns: ["tenant_id","attributed_venue_id"]
isOneToOne: false
      referencedRelation: "web_pos_venues"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "orders_delivery_lga_id_fkey"
      columns: ["delivery_lga_id"]
isOneToOne: false
      referencedRelation: "ng_lgas"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "orders_fulfilment_warehouse_fk"
      columns: ["tenant_id","fulfilment_warehouse_id"]
isOneToOne: false
      referencedRelation: "warehouses"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "orders_policy_version_tag_fkey"
      columns: ["policy_version_tag"]
isOneToOne: false
      referencedRelation: "refund_policies"
      referencedColumns: ["version_tag"]
    },{
      foreignKeyName: "orders_referral_code_fk"
      columns: ["tenant_id","referral_code_id"]
isOneToOne: false
      referencedRelation: "web_referral_codes"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "orders_retail_shop_id_fkey"
      columns: ["retail_shop_id"]
isOneToOne: false
      referencedRelation: "retail_shops"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "orders_teafair_agent_id_fkey"
      columns: ["teafair_agent_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "orders_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "orders_territory_fk"
      columns: ["tenant_id","territory_id"]
isOneToOne: false
      referencedRelation: "territories"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"otp_challenges": {
                  Row: {
                    "code_hash": string,"consumed_at": string | null,"created_at": string,"destination_phone": string,"expires_at": string,"failed_attempts": number,"id": string,"issued_by": string,"locked_until": string | null,"purpose": Database["public"]['Enums']["otp_purpose_enum"],"subject_id": string,"tenant_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "code_hash": string,"consumed_at"?: string | null,"created_at"?: string,"destination_phone": string,"expires_at": string,"failed_attempts"?: number,"id"?: string,"issued_by": string,"locked_until"?: string | null,"purpose": Database["public"]['Enums']["otp_purpose_enum"],"subject_id": string,"tenant_id"?: string | null
                  }
                  Update: {
                    "code_hash"?: string,"consumed_at"?: string | null,"created_at"?: string,"destination_phone"?: string,"expires_at"?: string,"failed_attempts"?: number,"id"?: string,"issued_by"?: string,"locked_until"?: string | null,"purpose"?: Database["public"]['Enums']["otp_purpose_enum"],"subject_id"?: string,"tenant_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "otp_challenges_issued_by_fkey"
      columns: ["issued_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "otp_challenges_subject_id_fkey"
      columns: ["subject_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "otp_challenges_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"payments": {
                  Row: {
                    "amount": number,"created_at": string,"customer_id": string | null,"gateway_provider": Database["public"]['Enums']["gateway_provider_enum"],"gateway_response_payload": Json | null,"id": string,"last_swept_at": string | null,"monvelo_access_code": string | null,"monvelo_agent_id": string | null,"monvelo_authorization_url": string | null,"monvelo_financing_id": string | null,"monvelo_started_by": string | null,"order_id": string,"otp_challenge_id": string | null,"payment_status": Database["public"]['Enums']["payment_status_enum"],"paystack_reference": string,"split_amount": number | null,"split_bps": number | null,"split_subaccount_code": string | null,"teafair_agent_id": string,"tenant_id": string,"updated_at": string,"web_pos_partner_id": string | null,"web_pos_venue_id": string | null,"payment_for_monvelo": boolean | null
                  }
                  ComputedFields: "payment_for_monvelo"
                  Insert: {
                    "amount": number,"created_at"?: string,"customer_id"?: string | null,"gateway_provider"?: Database["public"]['Enums']["gateway_provider_enum"],"gateway_response_payload"?: Json | null,"id"?: string,"last_swept_at"?: string | null,"monvelo_access_code"?: string | null,"monvelo_agent_id"?: string | null,"monvelo_authorization_url"?: string | null,"monvelo_financing_id"?: string | null,"monvelo_started_by"?: string | null,"order_id": string,"otp_challenge_id"?: string | null,"payment_status"?: Database["public"]['Enums']["payment_status_enum"],"paystack_reference": string,"split_amount"?: number | null,"split_bps"?: number | null,"split_subaccount_code"?: string | null,"teafair_agent_id": string,"tenant_id": string,"updated_at"?: string,"web_pos_partner_id"?: string | null,"web_pos_venue_id"?: string | null
                  }
                  Update: {
                    "amount"?: number,"created_at"?: string,"customer_id"?: string | null,"gateway_provider"?: Database["public"]['Enums']["gateway_provider_enum"],"gateway_response_payload"?: Json | null,"id"?: string,"last_swept_at"?: string | null,"monvelo_access_code"?: string | null,"monvelo_agent_id"?: string | null,"monvelo_authorization_url"?: string | null,"monvelo_financing_id"?: string | null,"monvelo_started_by"?: string | null,"order_id"?: string,"otp_challenge_id"?: string | null,"payment_status"?: Database["public"]['Enums']["payment_status_enum"],"paystack_reference"?: string,"split_amount"?: number | null,"split_bps"?: number | null,"split_subaccount_code"?: string | null,"teafair_agent_id"?: string,"tenant_id"?: string,"updated_at"?: string,"web_pos_partner_id"?: string | null,"web_pos_venue_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "payments_customer_id_fkey"
      columns: ["customer_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payments_monvelo_agent_id_fkey"
      columns: ["monvelo_agent_id"]
isOneToOne: false
      referencedRelation: "monvelo_agents"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payments_monvelo_financing_fk"
      columns: ["tenant_id","monvelo_financing_id"]
isOneToOne: false
      referencedRelation: "monvelo_financings"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "payments_monvelo_started_by_fkey"
      columns: ["monvelo_started_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payments_otp_challenge_id_fkey"
      columns: ["otp_challenge_id"]
isOneToOne: false
      referencedRelation: "otp_challenges"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payments_teafair_agent_id_fkey"
      columns: ["teafair_agent_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payments_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payments_tenant_id_order_id_fkey"
      columns: ["tenant_id","order_id"]
isOneToOne: false
      referencedRelation: "orders"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "payments_tenant_id_web_pos_partner_id_fkey"
      columns: ["tenant_id","web_pos_partner_id"]
isOneToOne: false
      referencedRelation: "web_pos_partners"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "payments_tenant_id_web_pos_venue_id_fkey"
      columns: ["tenant_id","web_pos_venue_id"]
isOneToOne: false
      referencedRelation: "web_pos_venues"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"profiles": {
                  Row: {
                    "created_at": string,"email": string | null,"full_name": string,"id": string,"kyc_status": Database["public"]['Enums']["kyc_status_enum"],"phone_number": string | null,"platform_role": Database["public"]['Enums']["platform_role_enum"] | null,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"email"?: string | null,"full_name"?: string,"id": string,"kyc_status"?: Database["public"]['Enums']["kyc_status_enum"],"phone_number"?: string | null,"platform_role"?: Database["public"]['Enums']["platform_role_enum"] | null,"updated_at"?: string
                  }
                  Update: {
                    "created_at"?: string,"email"?: string | null,"full_name"?: string,"id"?: string,"kyc_status"?: Database["public"]['Enums']["kyc_status_enum"],"phone_number"?: string | null,"platform_role"?: Database["public"]['Enums']["platform_role_enum"] | null,"updated_at"?: string
                  }
                  Relationships: [
                    
                  ]
                },"refund_policies": {
                  Row: {
                    "categories": (string)[],"content": string,"created_at": string,"id": string,"is_active": boolean,"published_at": string | null,"title": string,"version_tag": string
                  }
                  ComputedFields: never
                  Insert: {
                    "categories": (string)[],"content": string,"created_at"?: string,"id"?: string,"is_active"?: boolean,"published_at"?: string | null,"title": string,"version_tag": string
                  }
                  Update: {
                    "categories"?: (string)[],"content"?: string,"created_at"?: string,"id"?: string,"is_active"?: boolean,"published_at"?: string | null,"title"?: string,"version_tag"?: string
                  }
                  Relationships: [
                    
                  ]
                },"requisition_items": {
                  Row: {
                    "approved_qty": number | null,"fulfilled_qty": number | null,"id": string,"requested_qty": number,"requisition_id": string,"sku_code": string,"tenant_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "approved_qty"?: number | null,"fulfilled_qty"?: number | null,"id"?: string,"requested_qty": number,"requisition_id": string,"sku_code": string,"tenant_id": string
                  }
                  Update: {
                    "approved_qty"?: number | null,"fulfilled_qty"?: number | null,"id"?: string,"requested_qty"?: number,"requisition_id"?: string,"sku_code"?: string,"tenant_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "requisition_items_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "requisition_items_tenant_id_requisition_id_fkey"
      columns: ["tenant_id","requisition_id"]
isOneToOne: false
      referencedRelation: "requisitions"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "requisition_items_tenant_id_sku_code_fkey"
      columns: ["tenant_id","sku_code"]
isOneToOne: false
      referencedRelation: "central_products"
      referencedColumns: ["tenant_id","sku_code"]
    }
                  ]
                },"requisitions": {
                  Row: {
                    "created_at": string,"current_approval_level": Database["public"]['Enums']["tenant_role_enum"] | null,"dest_warehouse_id": string,"id": string,"requested_by": string,"required_approval_level": Database["public"]['Enums']["tenant_role_enum"],"source_warehouse_id": string,"status": string,"tenant_id": string,"total_value": number,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"current_approval_level"?: Database["public"]['Enums']["tenant_role_enum"] | null,"dest_warehouse_id": string,"id"?: string,"requested_by": string,"required_approval_level"?: Database["public"]['Enums']["tenant_role_enum"],"source_warehouse_id": string,"status"?: string,"tenant_id": string,"total_value"?: number,"updated_at"?: string
                  }
                  Update: {
                    "created_at"?: string,"current_approval_level"?: Database["public"]['Enums']["tenant_role_enum"] | null,"dest_warehouse_id"?: string,"id"?: string,"requested_by"?: string,"required_approval_level"?: Database["public"]['Enums']["tenant_role_enum"],"source_warehouse_id"?: string,"status"?: string,"tenant_id"?: string,"total_value"?: number,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "requisitions_requested_by_fkey"
      columns: ["requested_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "requisitions_tenant_id_dest_warehouse_id_fkey"
      columns: ["tenant_id","dest_warehouse_id"]
isOneToOne: false
      referencedRelation: "warehouses"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "requisitions_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "requisitions_tenant_id_source_warehouse_id_fkey"
      columns: ["tenant_id","source_warehouse_id"]
isOneToOne: false
      referencedRelation: "warehouses"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"retail_shops": {
                  Row: {
                    "address_text": string | null,"contact_phone": string,"created_at": string,"density_category": Database["public"]['Enums']["density_category_enum"],"id": string,"location": unknown,"owner_id": string | null,"preferred_agent_id": string | null,"shop_code": string | null,"shop_name": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "address_text"?: string | null,"contact_phone": string,"created_at"?: string,"density_category": Database["public"]['Enums']["density_category_enum"],"id"?: string,"location": unknown,"owner_id"?: string | null,"preferred_agent_id"?: string | null,"shop_code"?: string | null,"shop_name": string,"updated_at"?: string
                  }
                  Update: {
                    "address_text"?: string | null,"contact_phone"?: string,"created_at"?: string,"density_category"?: Database["public"]['Enums']["density_category_enum"],"id"?: string,"location"?: unknown,"owner_id"?: string | null,"preferred_agent_id"?: string | null,"shop_code"?: string | null,"shop_name"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "retail_shops_owner_id_fkey"
      columns: ["owner_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "retail_shops_preferred_agent_id_fkey"
      columns: ["preferred_agent_id"]
isOneToOne: false
      referencedRelation: "monvelo_agents"
      referencedColumns: ["id"]
    }
                  ]
                },"retail_stock_pickup_items": {
                  Row: {
                    "id": string,"pickup_id": string,"quantity_picked": number,"sku_code": string,"tenant_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "id"?: string,"pickup_id": string,"quantity_picked": number,"sku_code": string,"tenant_id": string
                  }
                  Update: {
                    "id"?: string,"pickup_id"?: string,"quantity_picked"?: number,"sku_code"?: string,"tenant_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "retail_stock_pickup_items_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "retail_stock_pickup_items_tenant_id_pickup_id_fkey"
      columns: ["tenant_id","pickup_id"]
isOneToOne: false
      referencedRelation: "retail_stock_pickups"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "retail_stock_pickup_items_tenant_id_sku_code_fkey"
      columns: ["tenant_id","sku_code"]
isOneToOne: false
      referencedRelation: "central_products"
      referencedColumns: ["tenant_id","sku_code"]
    }
                  ]
                },"retail_stock_pickups": {
                  Row: {
                    "confirmed_at": string | null,"confirmed_by": string | null,"created_at": string,"dsa_agent_id": string,"dsm_supervisor_id": string | null,"escalated_at": string | null,"event_tag": string | null,"id": string,"retail_shop_id": string,"status": string,"tenant_id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "confirmed_at"?: string | null,"confirmed_by"?: string | null,"created_at"?: string,"dsa_agent_id": string,"dsm_supervisor_id"?: string | null,"escalated_at"?: string | null,"event_tag"?: string | null,"id"?: string,"retail_shop_id": string,"status"?: string,"tenant_id": string,"updated_at"?: string
                  }
                  Update: {
                    "confirmed_at"?: string | null,"confirmed_by"?: string | null,"created_at"?: string,"dsa_agent_id"?: string,"dsm_supervisor_id"?: string | null,"escalated_at"?: string | null,"event_tag"?: string | null,"id"?: string,"retail_shop_id"?: string,"status"?: string,"tenant_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "retail_stock_pickups_confirmed_by_fkey"
      columns: ["confirmed_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "retail_stock_pickups_dsa_agent_id_fkey"
      columns: ["dsa_agent_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "retail_stock_pickups_dsm_supervisor_id_fkey"
      columns: ["dsm_supervisor_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "retail_stock_pickups_retail_shop_id_fkey"
      columns: ["retail_shop_id"]
isOneToOne: false
      referencedRelation: "retail_shops"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "retail_stock_pickups_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"route_waypoints": {
                  Row: {
                    "geofence_radius_m": number,"id": string,"landmark_name": string,"location": unknown,"route_id": string,"seq": number,"tenant_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "geofence_radius_m"?: number,"id"?: string,"landmark_name": string,"location": unknown,"route_id": string,"seq": number,"tenant_id": string
                  }
                  Update: {
                    "geofence_radius_m"?: number,"id"?: string,"landmark_name"?: string,"location"?: unknown,"route_id"?: string,"seq"?: number,"tenant_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "route_waypoints_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "route_waypoints_tenant_id_route_id_fkey"
      columns: ["tenant_id","route_id"]
isOneToOne: false
      referencedRelation: "routes"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"routes": {
                  Row: {
                    "assigned_staff_id": string,"created_at": string,"id": string,"route_date": string,"status": string,"tenant_id": string,"territory_id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "assigned_staff_id": string,"created_at"?: string,"id"?: string,"route_date": string,"status"?: string,"tenant_id": string,"territory_id": string,"updated_at"?: string
                  }
                  Update: {
                    "assigned_staff_id"?: string,"created_at"?: string,"id"?: string,"route_date"?: string,"status"?: string,"tenant_id"?: string,"territory_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "routes_assigned_staff_id_fkey"
      columns: ["assigned_staff_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "routes_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "routes_tenant_id_territory_id_fkey"
      columns: ["tenant_id","territory_id"]
isOneToOne: false
      referencedRelation: "territories"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"stock_movements": {
                  Row: {
                    "batch_number": string,"created_at": string,"decision_id": string | null,"id": string,"kind": string,"order_id": string | null,"quantity": number,"reason": string | null,"recorded_by": string,"sku_code": string,"tenant_id": string,"to_warehouse_id": string | null,"warehouse_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "batch_number": string,"created_at"?: string,"decision_id"?: string | null,"id"?: string,"kind": string,"order_id"?: string | null,"quantity": number,"reason"?: string | null,"recorded_by": string,"sku_code": string,"tenant_id": string,"to_warehouse_id"?: string | null,"warehouse_id": string
                  }
                  Update: {
                    "batch_number"?: string,"created_at"?: string,"decision_id"?: string | null,"id"?: string,"kind"?: string,"order_id"?: string | null,"quantity"?: number,"reason"?: string | null,"recorded_by"?: string,"sku_code"?: string,"tenant_id"?: string,"to_warehouse_id"?: string | null,"warehouse_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "stock_movements_order_fkey"
      columns: ["tenant_id","order_id"]
isOneToOne: false
      referencedRelation: "orders"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "stock_movements_recorded_by_fkey"
      columns: ["recorded_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "stock_movements_tenant_id_decision_id_fkey"
      columns: ["tenant_id","decision_id"]
isOneToOne: false
      referencedRelation: "contact_report_decisions"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "stock_movements_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "stock_movements_tenant_id_sku_code_fkey"
      columns: ["tenant_id","sku_code"]
isOneToOne: false
      referencedRelation: "central_products"
      referencedColumns: ["tenant_id","sku_code"]
    },{
      foreignKeyName: "stock_movements_tenant_id_to_warehouse_id_fkey"
      columns: ["tenant_id","to_warehouse_id"]
isOneToOne: false
      referencedRelation: "warehouses"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "stock_movements_tenant_id_warehouse_id_fkey"
      columns: ["tenant_id","warehouse_id"]
isOneToOne: false
      referencedRelation: "warehouses"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"stock_reservations": {
                  Row: {
                    "batch_id": string,"close_reason": string | null,"closed_at": string | null,"created_at": string,"expires_at": string | null,"id": string,"order_id": string,"order_item_id": string,"quantity": number,"sku_code": string,"status": string,"tenant_id": string,"warehouse_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "batch_id": string,"close_reason"?: string | null,"closed_at"?: string | null,"created_at"?: string,"expires_at"?: string | null,"id"?: string,"order_id": string,"order_item_id": string,"quantity": number,"sku_code": string,"status"?: string,"tenant_id": string,"warehouse_id": string
                  }
                  Update: {
                    "batch_id"?: string,"close_reason"?: string | null,"closed_at"?: string | null,"created_at"?: string,"expires_at"?: string | null,"id"?: string,"order_id"?: string,"order_item_id"?: string,"quantity"?: number,"sku_code"?: string,"status"?: string,"tenant_id"?: string,"warehouse_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "stock_reservations_tenant_id_batch_id_fkey"
      columns: ["tenant_id","batch_id"]
isOneToOne: false
      referencedRelation: "inventory_batches"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "stock_reservations_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "stock_reservations_tenant_id_order_id_fkey"
      columns: ["tenant_id","order_id"]
isOneToOne: false
      referencedRelation: "orders"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "stock_reservations_tenant_id_order_item_id_fkey"
      columns: ["tenant_id","order_item_id"]
isOneToOne: false
      referencedRelation: "order_items"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "stock_reservations_tenant_id_sku_code_fkey"
      columns: ["tenant_id","sku_code"]
isOneToOne: false
      referencedRelation: "central_products"
      referencedColumns: ["tenant_id","sku_code"]
    },{
      foreignKeyName: "stock_reservations_tenant_id_warehouse_id_fkey"
      columns: ["tenant_id","warehouse_id"]
isOneToOne: false
      referencedRelation: "warehouses"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"storage_purge_queue": {
                  Row: {
                    "bucket": string,"id": string,"path": string,"queued_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "bucket": string,"id"?: string,"path": string,"queued_at"?: string
                  }
                  Update: {
                    "bucket"?: string,"id"?: string,"path"?: string,"queued_at"?: string
                  }
                  Relationships: [
                    
                  ]
                },"support_messages": {
                  Row: {
                    "body": string,"created_at": string,"id": string,"redacted_at": string | null,"sender_id": string | null,"sender_type": string,"tenant_id": string,"territory_id": string | null,"ticket_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "body": string,"created_at"?: string,"id"?: string,"redacted_at"?: string | null,"sender_id"?: string | null,"sender_type": string,"tenant_id": string,"territory_id"?: string | null,"ticket_id": string
                  }
                  Update: {
                    "body"?: string,"created_at"?: string,"id"?: string,"redacted_at"?: string | null,"sender_id"?: string | null,"sender_type"?: string,"tenant_id"?: string,"territory_id"?: string | null,"ticket_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "support_messages_sender_id_fkey"
      columns: ["sender_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "support_messages_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "support_messages_tenant_id_territory_id_fkey"
      columns: ["tenant_id","territory_id"]
isOneToOne: false
      referencedRelation: "territories"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "support_messages_tenant_id_ticket_id_fkey"
      columns: ["tenant_id","ticket_id"]
isOneToOne: false
      referencedRelation: "support_tickets"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"support_ticket_contacts": {
                  Row: {
                    "created_at": string,"customer_email": string | null,"customer_name": string | null,"customer_phone": string | null,"redacted_at": string | null,"tenant_id": string,"territory_id": string | null,"ticket_id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"customer_email"?: string | null,"customer_name"?: string | null,"customer_phone"?: string | null,"redacted_at"?: string | null,"tenant_id": string,"territory_id"?: string | null,"ticket_id": string,"updated_at"?: string
                  }
                  Update: {
                    "created_at"?: string,"customer_email"?: string | null,"customer_name"?: string | null,"customer_phone"?: string | null,"redacted_at"?: string | null,"tenant_id"?: string,"territory_id"?: string | null,"ticket_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "support_ticket_contacts_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "support_ticket_contacts_tenant_id_territory_id_fkey"
      columns: ["tenant_id","territory_id"]
isOneToOne: false
      referencedRelation: "territories"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "support_ticket_contacts_tenant_id_ticket_id_fkey"
      columns: ["tenant_id","ticket_id"]
isOneToOne: false
      referencedRelation: "support_tickets"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"support_ticket_secrets": {
                  Row: {
                    "created_at": string,"secret_hash": string,"tenant_id": string,"ticket_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"secret_hash": string,"tenant_id": string,"ticket_id": string
                  }
                  Update: {
                    "created_at"?: string,"secret_hash"?: string,"tenant_id"?: string,"ticket_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "support_ticket_secrets_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "support_ticket_secrets_tenant_id_ticket_id_fkey"
      columns: ["tenant_id","ticket_id"]
isOneToOne: false
      referencedRelation: "support_tickets"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"support_tickets": {
                  Row: {
                    "accountable_id": string | null,"assigned_to": string | null,"category": string,"created_at": string,"id": string,"kind": string,"last_message_at": string,"order_id": string | null,"previous_ticket_id": string | null,"priority": string,"public_reference": string,"resolved_at": string | null,"status": string,"system_key": string | null,"tenant_id": string,"territory_id": string | null,"updated_at": string,"within_damage_window": boolean | null,"support_notify_activity": undefined | null
                  }
                  ComputedFields: "support_notify_activity"
                  Insert: {
                    "accountable_id"?: string | null,"assigned_to"?: string | null,"category": string,"created_at"?: string,"id"?: string,"kind": string,"last_message_at"?: string,"order_id"?: string | null,"previous_ticket_id"?: string | null,"priority"?: string,"public_reference": string,"resolved_at"?: string | null,"status"?: string,"system_key"?: string | null,"tenant_id": string,"territory_id"?: string | null,"updated_at"?: string,"within_damage_window"?: boolean | null
                  }
                  Update: {
                    "accountable_id"?: string | null,"assigned_to"?: string | null,"category"?: string,"created_at"?: string,"id"?: string,"kind"?: string,"last_message_at"?: string,"order_id"?: string | null,"previous_ticket_id"?: string | null,"priority"?: string,"public_reference"?: string,"resolved_at"?: string | null,"status"?: string,"system_key"?: string | null,"tenant_id"?: string,"territory_id"?: string | null,"updated_at"?: string,"within_damage_window"?: boolean | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "support_tickets_accountable_id_fkey"
      columns: ["accountable_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "support_tickets_assigned_to_fkey"
      columns: ["assigned_to"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "support_tickets_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "support_tickets_tenant_id_order_id_fkey"
      columns: ["tenant_id","order_id"]
isOneToOne: false
      referencedRelation: "orders"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "support_tickets_tenant_id_previous_ticket_id_fkey"
      columns: ["tenant_id","previous_ticket_id"]
isOneToOne: false
      referencedRelation: "support_tickets"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "support_tickets_tenant_id_territory_id_fkey"
      columns: ["tenant_id","territory_id"]
isOneToOne: false
      referencedRelation: "territories"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"tenant_allowed_categories": {
                  Row: {
                    "category": string,"created_at": string,"enabled": boolean,"tenant_id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "category": string,"created_at"?: string,"enabled"?: boolean,"tenant_id": string,"updated_at"?: string
                  }
                  Update: {
                    "category"?: string,"created_at"?: string,"enabled"?: boolean,"tenant_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "tenant_allowed_categories_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"tenant_operational_state_events": {
                  Row: {
                    "app_enabled": boolean,"changed_at": string,"changed_by": string,"decision_id": string,"id": string,"state_code": string,"tenant_id": string,"web_enabled": boolean
                  }
                  ComputedFields: never
                  Insert: {
                    "app_enabled": boolean,"changed_at"?: string,"changed_by": string,"decision_id": string,"id"?: string,"state_code": string,"tenant_id": string,"web_enabled": boolean
                  }
                  Update: {
                    "app_enabled"?: boolean,"changed_at"?: string,"changed_by"?: string,"decision_id"?: string,"id"?: string,"state_code"?: string,"tenant_id"?: string,"web_enabled"?: boolean
                  }
                  Relationships: [
                    {
      foreignKeyName: "tenant_operational_state_events_changed_by_fkey"
      columns: ["changed_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tenant_operational_state_events_state_code_fkey"
      columns: ["state_code"]
isOneToOne: false
      referencedRelation: "ng_states"
      referencedColumns: ["code"]
    },{
      foreignKeyName: "tenant_operational_state_events_tenant_id_decision_id_fkey"
      columns: ["tenant_id","decision_id"]
isOneToOne: false
      referencedRelation: "contact_report_decisions"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "tenant_operational_state_events_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"tenant_operational_states": {
                  Row: {
                    "app_enabled": boolean,"decision_id": string,"state_code": string,"tenant_id": string,"updated_at": string,"updated_by": string | null,"web_enabled": boolean
                  }
                  ComputedFields: never
                  Insert: {
                    "app_enabled"?: boolean,"decision_id": string,"state_code": string,"tenant_id": string,"updated_at"?: string,"updated_by"?: string | null,"web_enabled"?: boolean
                  }
                  Update: {
                    "app_enabled"?: boolean,"decision_id"?: string,"state_code"?: string,"tenant_id"?: string,"updated_at"?: string,"updated_by"?: string | null,"web_enabled"?: boolean
                  }
                  Relationships: [
                    {
      foreignKeyName: "tenant_operational_states_state_code_fkey"
      columns: ["state_code"]
isOneToOne: false
      referencedRelation: "ng_states"
      referencedColumns: ["code"]
    },{
      foreignKeyName: "tenant_operational_states_tenant_id_decision_id_fkey"
      columns: ["tenant_id","decision_id"]
isOneToOne: false
      referencedRelation: "contact_report_decisions"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "tenant_operational_states_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tenant_operational_states_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"tenant_settings": {
                  Row: {
                    "allow_shared_network": boolean,"currency": string,"custom_fields": NonNullable<Json>,"tenant_id": string,"timezone": string,"updated_at": string,"web_agent_commission_bps": number,"web_default_agent_id": string | null,"web_default_warehouse_id": string | null,"web_reservation_hours": number,"web_transport_fare": number
                  }
                  ComputedFields: never
                  Insert: {
                    "allow_shared_network"?: boolean,"currency"?: string,"custom_fields"?: NonNullable<Json>,"tenant_id": string,"timezone"?: string,"updated_at"?: string,"web_agent_commission_bps"?: number,"web_default_agent_id"?: string | null,"web_default_warehouse_id"?: string | null,"web_reservation_hours"?: number,"web_transport_fare"?: number
                  }
                  Update: {
                    "allow_shared_network"?: boolean,"currency"?: string,"custom_fields"?: NonNullable<Json>,"tenant_id"?: string,"timezone"?: string,"updated_at"?: string,"web_agent_commission_bps"?: number,"web_default_agent_id"?: string | null,"web_default_warehouse_id"?: string | null,"web_reservation_hours"?: number,"web_transport_fare"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "tenant_settings_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: true
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tenant_settings_web_default_agent_id_fkey"
      columns: ["web_default_agent_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tenant_settings_web_warehouse_fk"
      columns: ["tenant_id","web_default_warehouse_id"]
isOneToOne: false
      referencedRelation: "warehouses"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"tenant_shop_coverage": {
                  Row: {
                    "assigned_at": string,"assigned_by": string,"retail_shop_id": string,"tenant_id": string,"territory_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "assigned_at"?: string,"assigned_by": string,"retail_shop_id": string,"tenant_id": string,"territory_id": string
                  }
                  Update: {
                    "assigned_at"?: string,"assigned_by"?: string,"retail_shop_id"?: string,"tenant_id"?: string,"territory_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "tenant_shop_coverage_assigned_by_fkey"
      columns: ["assigned_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tenant_shop_coverage_retail_shop_id_fkey"
      columns: ["retail_shop_id"]
isOneToOne: false
      referencedRelation: "retail_shops"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tenant_shop_coverage_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tenant_shop_coverage_tenant_id_territory_id_fkey"
      columns: ["tenant_id","territory_id"]
isOneToOne: false
      referencedRelation: "territories"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"tenant_support_ticket_messages": {
                  Row: {
                    "body": string,"created_at": string,"id": string,"sender_id": string,"sender_side": string,"tenant_id": string,"ticket_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "body": string,"created_at"?: string,"id"?: string,"sender_id": string,"sender_side": string,"tenant_id": string,"ticket_id": string
                  }
                  Update: {
                    "body"?: string,"created_at"?: string,"id"?: string,"sender_id"?: string,"sender_side"?: string,"tenant_id"?: string,"ticket_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "tenant_support_ticket_messages_sender_id_fkey"
      columns: ["sender_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tenant_support_ticket_messages_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tenant_support_ticket_messages_tenant_id_ticket_id_fkey"
      columns: ["tenant_id","ticket_id"]
isOneToOne: false
      referencedRelation: "tenant_support_tickets"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"tenant_support_tickets": {
                  Row: {
                    "assigned_csm_id": string | null,"category": string,"created_at": string,"id": string,"last_message_at": string,"opened_by": string,"priority": string,"public_reference": string,"resolved_at": string | null,"status": string,"subject": string,"tenant_id": string,"updated_at": string,"tenant_ticket_live_csm": string | null,"tenant_ticket_notify_teafair": undefined | null
                  }
                  ComputedFields: "tenant_ticket_live_csm" | "tenant_ticket_notify_teafair"
                  Insert: {
                    "assigned_csm_id"?: string | null,"category": string,"created_at"?: string,"id"?: string,"last_message_at"?: string,"opened_by": string,"priority"?: string,"public_reference": string,"resolved_at"?: string | null,"status"?: string,"subject": string,"tenant_id": string,"updated_at"?: string
                  }
                  Update: {
                    "assigned_csm_id"?: string | null,"category"?: string,"created_at"?: string,"id"?: string,"last_message_at"?: string,"opened_by"?: string,"priority"?: string,"public_reference"?: string,"resolved_at"?: string | null,"status"?: string,"subject"?: string,"tenant_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "tenant_support_tickets_assigned_csm_id_fkey"
      columns: ["assigned_csm_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tenant_support_tickets_opened_by_fkey"
      columns: ["opened_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tenant_support_tickets_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    }
                  ]
                },"tenant_users": {
                  Row: {
                    "area_id": string | null,"created_at": string,"id": string,"is_primary": boolean,"pin_failed_attempts": number,"pin_hash": string | null,"pin_locked_until": string | null,"pin_pass_at": string | null,"profile_id": string,"reports_to_id": string | null,"role": Database["public"]['Enums']["tenant_role_enum"],"status": Database["public"]['Enums']["tenant_user_status_enum"],"tenant_id": string,"territory_id": string | null,"updated_at": string,"zone_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "area_id"?: string | null,"created_at"?: string,"id"?: string,"is_primary"?: boolean,"pin_failed_attempts"?: number,"pin_hash"?: string | null,"pin_locked_until"?: string | null,"pin_pass_at"?: string | null,"profile_id": string,"reports_to_id"?: string | null,"role": Database["public"]['Enums']["tenant_role_enum"],"status"?: Database["public"]['Enums']["tenant_user_status_enum"],"tenant_id": string,"territory_id"?: string | null,"updated_at"?: string,"zone_id"?: string | null
                  }
                  Update: {
                    "area_id"?: string | null,"created_at"?: string,"id"?: string,"is_primary"?: boolean,"pin_failed_attempts"?: number,"pin_hash"?: string | null,"pin_locked_until"?: string | null,"pin_pass_at"?: string | null,"profile_id"?: string,"reports_to_id"?: string | null,"role"?: Database["public"]['Enums']["tenant_role_enum"],"status"?: Database["public"]['Enums']["tenant_user_status_enum"],"tenant_id"?: string,"territory_id"?: string | null,"updated_at"?: string,"zone_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "tenant_users_area_fk"
      columns: ["tenant_id","territory_id","area_id"]
isOneToOne: false
      referencedRelation: "areas"
      referencedColumns: ["tenant_id","territory_id","id"]
    },{
      foreignKeyName: "tenant_users_profile_id_fkey"
      columns: ["profile_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tenant_users_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tenant_users_tenant_id_reports_to_id_fkey"
      columns: ["tenant_id","reports_to_id"]
isOneToOne: false
      referencedRelation: "tenant_users"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "tenant_users_tenant_id_territory_id_fkey"
      columns: ["tenant_id","territory_id"]
isOneToOne: false
      referencedRelation: "territories"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "tenant_users_tenant_id_zone_id_fkey"
      columns: ["tenant_id","zone_id"]
isOneToOne: false
      referencedRelation: "zones"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"tenants": {
                  Row: {
                    "code": string,"created_at": string,"id": string,"logo_url": string | null,"name": string,"status": Database["public"]['Enums']["tenant_status_enum"],"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "code": string,"created_at"?: string,"id"?: string,"logo_url"?: string | null,"name": string,"status"?: Database["public"]['Enums']["tenant_status_enum"],"updated_at"?: string
                  }
                  Update: {
                    "code"?: string,"created_at"?: string,"id"?: string,"logo_url"?: string | null,"name"?: string,"status"?: Database["public"]['Enums']["tenant_status_enum"],"updated_at"?: string
                  }
                  Relationships: [
                    
                  ]
                },"territories": {
                  Row: {
                    "boundary": unknown,"created_at": string,"id": string,"tenant_id": string,"territory_name": string,"tm_id": string | null,"web_fulfilment_warehouse_id": string | null,"zone_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "boundary"?: unknown,"created_at"?: string,"id"?: string,"tenant_id": string,"territory_name": string,"tm_id"?: string | null,"web_fulfilment_warehouse_id"?: string | null,"zone_id": string
                  }
                  Update: {
                    "boundary"?: unknown,"created_at"?: string,"id"?: string,"tenant_id"?: string,"territory_name"?: string,"tm_id"?: string | null,"web_fulfilment_warehouse_id"?: string | null,"zone_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "territories_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "territories_tenant_id_zone_id_fkey"
      columns: ["tenant_id","zone_id"]
isOneToOne: false
      referencedRelation: "zones"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "territories_tm_id_fkey"
      columns: ["tm_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "territories_web_warehouse_fk"
      columns: ["tenant_id","web_fulfilment_warehouse_id"]
isOneToOne: false
      referencedRelation: "warehouses"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"territory_coverage": {
                  Row: {
                    "created_at": string,"id": string,"lga_id": string | null,"state_code": string,"tenant_id": string,"territory_id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"id"?: string,"lga_id"?: string | null,"state_code": string,"tenant_id": string,"territory_id": string,"updated_at"?: string
                  }
                  Update: {
                    "created_at"?: string,"id"?: string,"lga_id"?: string | null,"state_code"?: string,"tenant_id"?: string,"territory_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "territory_coverage_lga_id_fkey"
      columns: ["lga_id"]
isOneToOne: false
      referencedRelation: "ng_lgas"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "territory_coverage_state_code_fkey"
      columns: ["state_code"]
isOneToOne: false
      referencedRelation: "ng_states"
      referencedColumns: ["code"]
    },{
      foreignKeyName: "territory_coverage_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "territory_coverage_tenant_id_territory_id_fkey"
      columns: ["tenant_id","territory_id"]
isOneToOne: false
      referencedRelation: "territories"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"upload_slots": {
                  Row: {
                    "bucket": string,"claimed_at": string | null,"created_at": string,"id": string,"message_id": string | null,"mime_type": string,"order_id": string | null,"purpose": string,"size_bytes": number,"storage_path": string,"tenant_id": string,"ticket_id": string | null,"uploaded_by": string | null,"uploaded_by_type": string
                  }
                  ComputedFields: never
                  Insert: {
                    "bucket"?: never,"claimed_at"?: string | null,"created_at"?: string,"id"?: string,"message_id"?: string | null,"mime_type": string,"order_id"?: string | null,"purpose": string,"size_bytes": number,"storage_path": string,"tenant_id": string,"ticket_id"?: string | null,"uploaded_by"?: string | null,"uploaded_by_type": string
                  }
                  Update: {
                    "bucket"?: never,"claimed_at"?: string | null,"created_at"?: string,"id"?: string,"message_id"?: string | null,"mime_type"?: string,"order_id"?: string | null,"purpose"?: string,"size_bytes"?: number,"storage_path"?: string,"tenant_id"?: string,"ticket_id"?: string | null,"uploaded_by"?: string | null,"uploaded_by_type"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "upload_slots_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "upload_slots_tenant_id_order_id_fkey"
      columns: ["tenant_id","order_id"]
isOneToOne: false
      referencedRelation: "orders"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "upload_slots_tenant_id_ticket_id_fkey"
      columns: ["tenant_id","ticket_id"]
isOneToOne: false
      referencedRelation: "support_tickets"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "upload_slots_tenant_id_ticket_id_message_id_fkey"
      columns: ["tenant_id","ticket_id","message_id"]
isOneToOne: false
      referencedRelation: "support_messages"
      referencedColumns: ["tenant_id","ticket_id","id"]
    },{
      foreignKeyName: "upload_slots_uploaded_by_fkey"
      columns: ["uploaded_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"user_secure_profiles": {
                  Row: {
                    "bank_account_number": string | null,"bank_code": string | null,"bank_name": string | null,"bvn_hash_prev_version": number | null,"bvn_hash_version": number,"bvn_nin_hash": string,"bvn_nin_hash_prev": string | null,"created_at": string,"updated_at": string,"user_id": string,"verified_at": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "bank_account_number"?: string | null,"bank_code"?: string | null,"bank_name"?: string | null,"bvn_hash_prev_version"?: number | null,"bvn_hash_version": number,"bvn_nin_hash": string,"bvn_nin_hash_prev"?: string | null,"created_at"?: string,"updated_at"?: string,"user_id": string,"verified_at"?: string | null
                  }
                  Update: {
                    "bank_account_number"?: string | null,"bank_code"?: string | null,"bank_name"?: string | null,"bvn_hash_prev_version"?: number | null,"bvn_hash_version"?: number,"bvn_nin_hash"?: string,"bvn_nin_hash_prev"?: string | null,"created_at"?: string,"updated_at"?: string,"user_id"?: string,"verified_at"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "user_secure_profiles_user_id_fkey"
      columns: ["user_id"]
isOneToOne: true
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"warehouses": {
                  Row: {
                    "created_at": string,"id": string,"kind": Database["public"]['Enums']["warehouse_kind_enum"],"location": unknown,"manager_id": string | null,"name": string,"tenant_id": string,"territory_id": string | null,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"id"?: string,"kind": Database["public"]['Enums']["warehouse_kind_enum"],"location"?: unknown,"manager_id"?: string | null,"name": string,"tenant_id": string,"territory_id"?: string | null,"updated_at"?: string
                  }
                  Update: {
                    "created_at"?: string,"id"?: string,"kind"?: Database["public"]['Enums']["warehouse_kind_enum"],"location"?: unknown,"manager_id"?: string | null,"name"?: string,"tenant_id"?: string,"territory_id"?: string | null,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "warehouses_manager_id_fkey"
      columns: ["manager_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "warehouses_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "warehouses_tenant_id_territory_id_fkey"
      columns: ["tenant_id","territory_id"]
isOneToOne: false
      referencedRelation: "territories"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"web_commissions": {
                  Row: {
                    "amount": number,"bps_applied": number,"created_at": string,"dispute_reason": string | null,"id": string,"order_id": string,"payment_id": string,"paystack_settlement_id": string | null,"paystack_split_reference": string | null,"paystack_subaccount_code": string,"settled_at": string | null,"status": Database["public"]['Enums']["commission_status_enum"],"teafair_agent_id": string,"tenant_id": string,"updated_at": string,"web_pos_partner_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "amount": number,"bps_applied": number,"created_at"?: string,"dispute_reason"?: string | null,"id"?: string,"order_id": string,"payment_id": string,"paystack_settlement_id"?: string | null,"paystack_split_reference"?: string | null,"paystack_subaccount_code": string,"settled_at"?: string | null,"status"?: Database["public"]['Enums']["commission_status_enum"],"teafair_agent_id": string,"tenant_id": string,"updated_at"?: string,"web_pos_partner_id": string
                  }
                  Update: {
                    "amount"?: number,"bps_applied"?: number,"created_at"?: string,"dispute_reason"?: string | null,"id"?: string,"order_id"?: string,"payment_id"?: string,"paystack_settlement_id"?: string | null,"paystack_split_reference"?: string | null,"paystack_subaccount_code"?: string,"settled_at"?: string | null,"status"?: Database["public"]['Enums']["commission_status_enum"],"teafair_agent_id"?: string,"tenant_id"?: string,"updated_at"?: string,"web_pos_partner_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "web_commissions_teafair_agent_id_fkey"
      columns: ["teafair_agent_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "web_commissions_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "web_commissions_tenant_id_order_id_fkey"
      columns: ["tenant_id","order_id"]
isOneToOne: false
      referencedRelation: "orders"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "web_commissions_tenant_id_payment_id_fkey"
      columns: ["tenant_id","payment_id"]
isOneToOne: true
      referencedRelation: "payments"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "web_commissions_tenant_id_web_pos_partner_id_fkey"
      columns: ["tenant_id","web_pos_partner_id"]
isOneToOne: false
      referencedRelation: "web_pos_partners"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"web_phone_verifications": {
                  Row: {
                    "client_ip": unknown,"code_hash": string,"consumed_at": string | null,"created_at": string,"expires_at": string,"failed_attempts": number,"id": string,"phone": string,"token_expires_at": string | null,"token_hash": string | null,"verified_at": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "client_ip"?: unknown,"code_hash": string,"consumed_at"?: string | null,"created_at"?: string,"expires_at": string,"failed_attempts"?: number,"id"?: string,"phone": string,"token_expires_at"?: string | null,"token_hash"?: string | null,"verified_at"?: string | null
                  }
                  Update: {
                    "client_ip"?: unknown,"code_hash"?: string,"consumed_at"?: string | null,"created_at"?: string,"expires_at"?: string,"failed_attempts"?: number,"id"?: string,"phone"?: string,"token_expires_at"?: string | null,"token_hash"?: string | null,"verified_at"?: string | null
                  }
                  Relationships: [
                    
                  ]
                },"web_pos_partners": {
                  Row: {
                    "approved_at": string | null,"approved_by": string | null,"business_name": string,"contact_phone": string,"created_at": string,"id": string,"paystack_subaccount_code": string,"pos_network": Database["public"]['Enums']["pos_network_enum"],"status": string,"tenant_id": string,"territory_id": string | null,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "approved_at"?: string | null,"approved_by"?: string | null,"business_name": string,"contact_phone": string,"created_at"?: string,"id"?: string,"paystack_subaccount_code": string,"pos_network": Database["public"]['Enums']["pos_network_enum"],"status"?: string,"tenant_id": string,"territory_id"?: string | null,"updated_at"?: string
                  }
                  Update: {
                    "approved_at"?: string | null,"approved_by"?: string | null,"business_name"?: string,"contact_phone"?: string,"created_at"?: string,"id"?: string,"paystack_subaccount_code"?: string,"pos_network"?: Database["public"]['Enums']["pos_network_enum"],"status"?: string,"tenant_id"?: string,"territory_id"?: string | null,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "web_pos_partners_approved_by_fkey"
      columns: ["approved_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "web_pos_partners_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "web_pos_partners_tenant_id_territory_id_fkey"
      columns: ["tenant_id","territory_id"]
isOneToOne: false
      referencedRelation: "territories"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"web_pos_venues": {
                  Row: {
                    "address_text": string | null,"agent_id": string | null,"created_at": string,"id": string,"is_active": boolean,"lga": string | null,"location": unknown,"network_terminal_id": string,"operating_hours": Json | null,"partner_id": string,"state": string | null,"tenant_id": string,"territory_id": string | null,"updated_at": string,"venue_channel": Database["public"]['Enums']["venue_channel_enum"] | null,"venue_name": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "address_text"?: string | null,"agent_id"?: string | null,"created_at"?: string,"id"?: string,"is_active"?: boolean,"lga"?: string | null,"location"?: unknown,"network_terminal_id": string,"operating_hours"?: Json | null,"partner_id": string,"state"?: string | null,"tenant_id": string,"territory_id"?: string | null,"updated_at"?: string,"venue_channel"?: Database["public"]['Enums']["venue_channel_enum"] | null,"venue_name"?: string | null
                  }
                  Update: {
                    "address_text"?: string | null,"agent_id"?: string | null,"created_at"?: string,"id"?: string,"is_active"?: boolean,"lga"?: string | null,"location"?: unknown,"network_terminal_id"?: string,"operating_hours"?: Json | null,"partner_id"?: string,"state"?: string | null,"tenant_id"?: string,"territory_id"?: string | null,"updated_at"?: string,"venue_channel"?: Database["public"]['Enums']["venue_channel_enum"] | null,"venue_name"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "web_pos_venues_agent_id_fkey"
      columns: ["agent_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "web_pos_venues_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "web_pos_venues_tenant_id_partner_id_fkey"
      columns: ["tenant_id","partner_id"]
isOneToOne: false
      referencedRelation: "web_pos_partners"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "web_pos_venues_tenant_id_territory_id_fkey"
      columns: ["tenant_id","territory_id"]
isOneToOne: false
      referencedRelation: "territories"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"web_referral_codes": {
                  Row: {
                    "agent_id": string,"code": string,"created_at": string,"created_by": string,"discount_type": string | null,"discount_value": number | null,"expires_at": string | null,"id": string,"is_active": boolean,"max_redemptions": number | null,"tenant_id": string,"updated_at": string,"venue_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "agent_id": string,"code": string,"created_at"?: string,"created_by": string,"discount_type"?: string | null,"discount_value"?: number | null,"expires_at"?: string | null,"id"?: string,"is_active"?: boolean,"max_redemptions"?: number | null,"tenant_id": string,"updated_at"?: string,"venue_id"?: string | null
                  }
                  Update: {
                    "agent_id"?: string,"code"?: string,"created_at"?: string,"created_by"?: string,"discount_type"?: string | null,"discount_value"?: number | null,"expires_at"?: string | null,"id"?: string,"is_active"?: boolean,"max_redemptions"?: number | null,"tenant_id"?: string,"updated_at"?: string,"venue_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "web_referral_codes_agent_id_fkey"
      columns: ["agent_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "web_referral_codes_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "web_referral_codes_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "web_referral_codes_tenant_id_venue_id_fkey"
      columns: ["tenant_id","venue_id"]
isOneToOne: false
      referencedRelation: "web_pos_venues"
      referencedColumns: ["tenant_id","id"]
    }
                  ]
                },"zones": {
                  Row: {
                    "boundary": unknown,"created_at": string,"id": string,"state_code": string,"tenant_id": string,"zone_name": string,"zsm_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "boundary"?: unknown,"created_at"?: string,"id"?: string,"state_code": string,"tenant_id": string,"zone_name": string,"zsm_id"?: string | null
                  }
                  Update: {
                    "boundary"?: unknown,"created_at"?: string,"id"?: string,"state_code"?: string,"tenant_id"?: string,"zone_name"?: string,"zsm_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "zones_state_code_fkey"
      columns: ["state_code"]
isOneToOne: false
      referencedRelation: "ng_states"
      referencedColumns: ["code"]
    },{
      foreignKeyName: "zones_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "zones_zsm_id_fkey"
      columns: ["zsm_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                }
          }
          Views: {
            [_ in never]: never
          }
          Functions: {
            "accept_monvelo_agent_terms":
{ Args: { "p_agent_id": string,"p_body_sha256": string,"p_idempotency_key": string,"p_terms_code": string }; Returns: Json
                           },
"accept_monvelo_tenant_terms":
{ Args: { "p_body_sha256": string,"p_decision_id": string,"p_idempotency_key": string,"p_terms_code": string }; Returns: Json
                           },
"accept_tenant_invitation":
{ Args: { "p_idempotency_key": string,"p_tenant_user_id": string }; Returns: Json
                           },
"access_token_claims":
{ Args: { "p_user_id": string }; Returns: Json
                           },
"add_monvelo_member":
{ Args: { "p_agent_id": string,"p_contact": string,"p_idempotency_key": string }; Returns: Json
                           },
"add_ticket_message":
{ Args: { "p_attachment_ids"?: (string)[],"p_idempotency_key": string,"p_message": string,"p_public_reference": string,"p_secret": string }; Returns: Json
                           },
"apply_monvelo_insurer_event":
{ Args: { "p_event": Json,"p_event_id": string,"p_insurer_code": string,"p_type": string }; Returns: Json
                           },
"apply_monvelo_refund":
{ Args: { "p_amount_minor": number,"p_currency": string,"p_reason": string,"p_refund_id": string,"p_source": string,"p_transaction_reference": string,"p_verified": Json }; Returns: Json
                           },
"apply_paystack_refund":
{ Args: { "p_amount_minor": number,"p_currency": string,"p_reason": string,"p_refund_id": string,"p_source": string,"p_transaction_reference": string,"p_verified": Json }; Returns: Json
                           },
"appoint_client_service_manager":
{ Args: { "p_contact": string,"p_idempotency_key": string,"p_tenant_id": string }; Returns: Json
                           },
"appoint_zone_manager":
{ Args: { "p_contact": string,"p_idempotency_key": string,"p_tenant_id": string }; Returns: Json
                           },
"approval_rank":
{ Args: { "p_role": Database["public"]['Enums']["tenant_role_enum"] }; Returns: number
                           },
"approve_monvelo_agent":
{ Args: { "p_agent_id": string,"p_idempotency_key": string }; Returns: Json
                           },
"approve_monvelo_brand_terms":
{ Args: { "p_decision_id"?: string,"p_idempotency_key": string,"p_terms_id": string }; Returns: Json
                           },
"approve_monvelo_financing":
{ Args: { "p_financing_id": string,"p_idempotency_key": string }; Returns: Json
                           },
"approve_monvelo_insurance_product":
{ Args: { "p_idempotency_key": string,"p_product_id": string }; Returns: Json
                           },
"approve_monvelo_settlement_change":
{ Args: { "p_agent_id": string,"p_idempotency_key": string }; Returns: Json
                           },
"assert_authenticated":
{ Args: Record<PropertyKey, never>; Returns: string
                           },
"assert_citable_decision":
{ Args: { "p_decision_id": string,"p_subject": string,"p_tenant_id": string }; Returns: {
              "created_at": string,
"decision_text": string,
"id": string,
"report_id": string,
"seq": number,
"subject": string,
"tenant_id": string
            }
                          SetofOptions: {
        from: "*"
        to: "contact_report_decisions"
        isOneToOne: true
        isSetofReturn: false
      } },
"assert_gateway_proof":
{ Args: { "p_proof": string }; Returns: undefined
                           },
"assert_platform_role":
{ Args: { "p_roles": (Database["public"]['Enums']["platform_role_enum"])[] }; Returns: string
                           },
"assert_state_app_operational":
{ Args: { "p_tenant_id": string,"p_territory_id": string }; Returns: undefined
                           },
"assert_tenant_role":
{ Args: { "p_roles": (Database["public"]['Enums']["tenant_role_enum"])[] }; Returns: {
              "area_id": string | null,
"created_at": string,
"id": string,
"is_primary": boolean,
"pin_failed_attempts": number,
"pin_hash": string | null,
"pin_locked_until": string | null,
"pin_pass_at": string | null,
"profile_id": string,
"reports_to_id": string | null,
"role": Database["public"]['Enums']["tenant_role_enum"],
"status": Database["public"]['Enums']["tenant_user_status_enum"],
"tenant_id": string,
"territory_id": string | null,
"updated_at": string,
"zone_id": string | null
            }
                          SetofOptions: {
        from: "*"
        to: "tenant_users"
        isOneToOne: true
        isSetofReturn: false
      } },
"assert_wholesale_pack":
{ Args: { "p_qty": number,"p_sku_code": string,"p_tenant_id": string }; Returns: undefined
                           },
"assign_tenant_ticket":
{ Args: { "p_csm_profile_id": string,"p_idempotency_key": string,"p_ticket_id": string }; Returns: Json
                           },
"assign_ticket":
{ Args: { "p_idempotency_key": string,"p_territory_id": string,"p_ticket_id": string }; Returns: Json
                           },
"attach_contact_report_hard_copy":
{ Args: { "p_hard_copy_id": string,"p_idempotency_key": string }; Returns: Json
                           },
"auth_contact_request":
{ Args: { "p_contact": string }; Returns: Json
                           },
"auth_email_context":
{ Args: { "p_user_id": string }; Returns: Json
                           },
"auth_sms_allowed":
{ Args: { "p_phone": string,"p_user_id": string }; Returns: boolean
                           },
"can_upload_monvelo_cover":
{ Args: { "p_purpose": string,"p_subject_id": string }; Returns: boolean
                           },
"cancel_monvelo_financing":
{ Args: { "p_financing_id": string,"p_idempotency_key": string,"p_reason": string }; Returns: Json
                           },
"change_tenant_pin":
{ Args: { "p_current_pin": string,"p_idempotency_key": string,"p_new_pin": string }; Returns: Json
                           },
"chat_is_available":
{ Args: { "p_profile": string,"p_tenant": string }; Returns: boolean
                           },
"chat_staff_zone":
{ Args: { "p_profile": string,"p_tenant": string }; Returns: string
                           },
"chat_staff_zone_ids":
{ Args: { "p_profile": string,"p_tenant": string }; Returns: string[]
                           },
"claim_email_outbox":
{ Args: { "p_limit": number }; Returns: {
              "attempts": number,
"created_at": string,
"id": string,
"next_attempt_at": string,
"payload": NonNullable<Json>,
"sent_at": string | null,
"source_id": string,
"source_table": string,
"status": string,
"template": string,
"to_email": string | null
            }[]
                          SetofOptions: {
        from: "*"
        to: "email_outbox"
        isOneToOne: false
        isSetofReturn: true
      } },
"claim_monvelo_declarations":
{ Args: { "p_limit"?: number }; Returns: Json[]
                           },
"claim_monvelo_financing":
{ Args: { "p_agent_id": string,"p_expected_net_yield_bps": number,"p_financing_id": string,"p_idempotency_key": string }; Returns: Json
                           },
"claim_support_attachments":
{ Args: { "p_ids": (string)[],"p_message_id": string,"p_ticket_id": string,"p_uploader_type": string }; Returns: number
                           },
"claim_tenant_ticket":
{ Args: { "p_idempotency_key": string,"p_ticket_id": string }; Returns: Json
                           },
"claim_ticket":
{ Args: { "p_idempotency_key": string,"p_ticket_id": string }; Returns: Json
                           },
"claim_unconfirmed_payments":
{ Args: { "p_limit": number }; Returns: {
              "created_at": string,"paystack_reference": string
            }[]
                           },
"cleanup_pending_upload_slots":
{ Args: Record<PropertyKey, never>; Returns: number
                           },
"cleanup_web_phone_verifications":
{ Args: Record<PropertyKey, never>; Returns: number
                           },
"close_monvelo_insurance_claim":
{ Args: { "p_claim_id": string,"p_idempotency_key": string,"p_reason": string }; Returns: Json
                           },
"close_monvelo_nomination":
{ Args: { "p_agent_id": string,"p_idempotency_key": string,"p_nomination_id": string,"p_status": string }; Returns: Json
                           },
"close_resolved_support_tickets":
{ Args: Record<PropertyKey, never>; Returns: number
                           },
"close_resolved_tenant_tickets":
{ Args: Record<PropertyKey, never>; Returns: number
                           },
"complete_email_outbox":
{ Args: { "p_id": string,"p_result": string }; Returns: undefined
                           },
"complete_monvelo_declaration":
{ Args: { "p_error": string,"p_id": string,"p_insurer_reference": string,"p_outcome": string }; Returns: Json
                           },
"confirm_monvelo_delivery":
{ Args: { "p_challenge_id": string,"p_code": string,"p_idempotency_key": string }; Returns: Json
                           },
"confirm_monvelo_repayment":
{ Args: { "p_challenge_id": string,"p_code": string,"p_idempotency_key": string }; Returns: Json
                           },
"confirm_web_phone_verification":
{ Args: { "p_code": string,"p_token_hash": string,"p_verification_id": string }; Returns: Json
                           },
"consume_pin_pass":
{ Args: Record<PropertyKey, never>; Returns: undefined
                           },
"contact_report_draw_reference":
{ Args: Record<PropertyKey, never>; Returns: string
                           },
"contact_report_recipient_clean":
{ Args: { "p_recipient": Json }; Returns: Json
                           },
"create_zone":
{ Args: { "p_idempotency_key": string,"p_state_code": string,"p_tenant_id": string }; Returns: Json
                           },
"decide_monvelo_claim_hold":
{ Args: { "p_allow": boolean,"p_hold_id": string,"p_idempotency_key": string,"p_reason": string }; Returns: Json
                           },
"decline_tenant_invitation":
{ Args: { "p_idempotency_key": string,"p_tenant_user_id": string }; Returns: Json
                           },
"dispatch_monvelo_financing":
{ Args: { "p_financing_id": string,"p_idempotency_key": string,"p_tracking_reference": string }; Returns: Json
                           },
"enqueue_email":
{ Args: { "p_payload": Json,"p_source_id": string,"p_source_table": string,"p_template": string,"p_to_email": string }; Returns: undefined
                           },
"enrol_monvelo_shop":
{ Args: { "p_challenge_id": string,"p_code": string,"p_idempotency_key": string }; Returns: Json
                           },
"escalate_stale_pickups":
{ Args: Record<PropertyKey, never>; Returns: number
                           },
"expire_unsettled_commissions":
{ Args: Record<PropertyKey, never>; Returns: number
                           },
"file_contact_report":
{ Args: { "p_idempotency_key": string,"p_report": Json }; Returns: Json
                           },
"file_monvelo_insurance_claim":
{ Args: { "p_claim_id": string,"p_idempotency_key": string }; Returns: Json
                           },
"fulfilment_can_dispatch":
{ Args: { "p_me": Omit<Database["public"]['Tables']["tenant_users"]['Row'], Database["public"]['Tables']["tenant_users"]['ComputedFields']>,"p_order": Omit<Database["public"]['Tables']["orders"]['Row'], Database["public"]['Tables']["orders"]['ComputedFields']> }; Returns: boolean
                           },
"fulfilment_delivery_path":
{ Args: { "p_me": Omit<Database["public"]['Tables']["tenant_users"]['Row'], Database["public"]['Tables']["tenant_users"]['ComputedFields']>,"p_order": Omit<Database["public"]['Tables']["orders"]['Row'], Database["public"]['Tables']["orders"]['ComputedFields']> }; Returns: string
                           },
"fulfilment_lock_order":
{ Args: { "p_me": Omit<Database["public"]['Tables']["tenant_users"]['Row'], Database["public"]['Tables']["tenant_users"]['ComputedFields']>,"p_order_id": string }; Returns: {
              "agent_id": string | null,
"attributed_agent_id": string | null,
"attributed_venue_id": string | null,
"channel": Database["public"]['Enums']["order_channel_enum"],
"created_at": string,
"delivery_lga_id": string | null,
"discount_amount": number,
"fulfilment_warehouse_id": string | null,
"id": string,
"payment_route": string | null,
"policy_accepted_at": string | null,
"policy_version_tag": string | null,
"public_reference": string | null,
"referral_code_id": string | null,
"retail_shop_id": string | null,
"status": string,
"teafair_agent_id": string,
"tenant_id": string,
"territory_id": string | null,
"total_amount": number,
"tracking_reference": string | null,
"transport_fare": number,
"updated_at": string,
"utm_campaign": string | null,
"utm_medium": string | null,
"utm_source": string | null
            }
                          SetofOptions: {
        from: "*"
        to: "orders"
        isOneToOne: true
        isSetofReturn: false
      } },
"fulfilment_today":
{ Args: Record<PropertyKey, never>; Returns: string
                           },
"geojson_to_multipolygon":
{ Args: { "p_geojson": Json }; Returns: unknown
                           },
"get_lender_reconciliation_summary":
{ Args: { "p_weeks"?: number }; Returns: {
              "agent_id": string,"agent_name": string,"capital_funded": number,"closed_by_claim_amount": number,"late_charge_waived": number,"mv_references": (string)[],"outstanding": number,"rebates_owed": number,"rebates_paid": number,"refunded": number,"repaid": number,"week_start": string
            }[]
                           },
"get_monvelo_agent_exposure":
{ Args: { "p_agent_id"?: string }; Returns: {
              "active_commitments_count": number,"agent_id": string,"agent_status": string,"allowance_ceiling": number,"open_exposure": number,"per_financing_limit": number,"personal_daily_limit": number,"platform_ceiling": number,"remaining_room": number,"today_remaining_limit": number,"today_utilized_limit": number
            }[]
                           },
"get_monvelo_claim_hold":
{ Args: { "p_hold_id": string }; Returns: {
              "area_name": string,"blocks": (string)[],"brand_lines": Json,"can_decide": boolean,"decided_at": string,"decided_by_name": string,"expires_at": string,"financing_reference": string,"hold_id": string,"principal": number,"ready": boolean,"reason": string,"shop_code": string,"shop_defaulted": number,"shop_limits": Json,"shop_name": string,"shop_open": number,"shop_repaid_in_window": number,"shop_repaid_late": number,"status": string,"within_limit": boolean
            }[]
                           },
"get_monvelo_field_dashboard":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"get_monvelo_insurer_provider":
{ Args: { "p_code": string }; Returns: string
                           },
"get_monvelo_offer_cover":
{ Args: { "p_agent_id": string,"p_financing_id": string }; Returns: {
              "cover_label": string,"gross_rebate": number,"net_rebate": number,"net_yield_bps": number,"net_yield_percent": number,"quote_valid_until": string,"storage_premium": number
            }[]
                           },
"get_monvelo_tm_oversight":
{ Args: { "p_days"?: number }; Returns: Json
                           },
"get_my_pin_status":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"get_or_create_direct_channel":
{ Args: { "p_idempotency_key": string,"p_target_profile_id": string }; Returns: Json
                           },
"get_order_dispute_evidence":
{ Args: { "p_order_id": string }; Returns: Json
                           },
"hide_chat_message":
{ Args: { "p_idempotency_key": string,"p_message_id": string,"p_reason": string }; Returns: Json
                           },
"idempotency_begin":
{ Args: { "p_key": string,"p_operation": string,"p_request": Json }; Returns: Json
                           },
"idempotency_complete":
{ Args: { "p_key": string,"p_response": Json }; Returns: Json
                           },
"invite_tenant_user":
{ Args: { "p_area_id"?: string,"p_contact": string,"p_idempotency_key": string,"p_reports_to_id": string,"p_role": Database["public"]['Enums']["tenant_role_enum"],"p_territory_id": string }; Returns: Json
                           },
"invoke_system_function":
{ Args: { "p_body": Json,"p_function": string }; Returns: number
                           },
"is_monvelo_agent_member":
{ Args: { "p_user_id": string }; Returns: boolean
                           },
"is_monvelo_field_agent":
{ Args: Record<PropertyKey, never>; Returns: boolean
                           },
"is_monvelo_operator":
{ Args: Record<PropertyKey, never>; Returns: boolean
                           },
"is_monvelo_staff":
{ Args: Record<PropertyKey, never>; Returns: boolean
                           },
"is_platform_staff":
{ Args: Record<PropertyKey, never>; Returns: boolean
                           },
"is_tenant_member":
{ Args: { "p_tenant_id": string }; Returns: boolean
                           },
"issue_otp":
{ Args: { "p_gateway_proof": string,"p_idempotency_key": string,"p_purpose": Database["public"]['Enums']["otp_purpose_enum"],"p_subject_id": string }; Returns: Json
                           },
"jwt_tenant_id":
{ Args: Record<PropertyKey, never>; Returns: string
                           },
"list_monvelo_claim_holds":
{ Args: Record<PropertyKey, never>; Returns: {
              "area_name": string,"blocks": (string)[],"brand_lines": Json,"can_decide": boolean,"decided_at": string,"decided_by_name": string,"expires_at": string,"financing_reference": string,"hold_id": string,"principal": number,"ready": boolean,"reason": string,"shop_code": string,"shop_defaulted": number,"shop_limits": Json,"shop_name": string,"shop_open": number,"shop_repaid_in_window": number,"shop_repaid_late": number,"status": string,"within_limit": boolean
            }[]
                           },
"list_my_chat_channels":
{ Args: Record<PropertyKey, never>; Returns: Json[]
                           },
"list_my_invitations":
{ Args: Record<PropertyKey, never>; Returns: {
              "area_name": string,"invited_at": string,"role": Database["public"]['Enums']["tenant_role_enum"],"tenant_code": string,"tenant_id": string,"tenant_name": string,"tenant_user_id": string,"territory_name": string,"zone_name": string
            }[]
                           },
"list_unsettled_subaccounts":
{ Args: Record<PropertyKey, never>; Returns: {
              "oldest_at": string,"payment_references": (string)[],"subaccount_code": string
            }[]
                           },
"lock_my_invitation":
{ Args: { "p_tenant_user_id": string }; Returns: {
              "area_id": string | null,
"created_at": string,
"id": string,
"is_primary": boolean,
"pin_failed_attempts": number,
"pin_hash": string | null,
"pin_locked_until": string | null,
"pin_pass_at": string | null,
"profile_id": string,
"reports_to_id": string | null,
"role": Database["public"]['Enums']["tenant_role_enum"],
"status": Database["public"]['Enums']["tenant_user_status_enum"],
"tenant_id": string,
"territory_id": string | null,
"updated_at": string,
"zone_id": string | null
            }
                          SetofOptions: {
        from: "*"
        to: "tenant_users"
        isOneToOne: true
        isSetofReturn: false
      } },
"log_message_delivery":
{ Args: { "p_channel": string,"p_phone": string,"p_purpose": string,"p_related_id": string,"p_status": string,"p_tenant_id": string,"p_whatsapp_error": string }; Returns: undefined
                           },
"mark_chat_read":
{ Args: { "p_channel_id": string,"p_idempotency_key": string,"p_read_up_to": string }; Returns: Json
                           },
"mark_delivery_pin_sent":
{ Args: { "p_channel": string,"p_gateway_proof": string,"p_idempotency_key": string,"p_order_id": string }; Returns: Json
                           },
"mark_order_delivered":
{ Args: { "p_idempotency_key": string,"p_order_id": string,"p_photo_attachment_id"?: string,"p_pin": string }; Returns: Json
                           },
"mark_order_dispatched":
{ Args: { "p_gateway_proof": string,"p_idempotency_key": string,"p_order_id": string,"p_pin": string,"p_tracking_reference": string }; Returns: Json
                           },
"monvelo_active_insurer":
{ Args: { "p_code": string }; Returns: string
                           },
"monvelo_agent_audit":
{ Args: { "p_agent": Omit<Database["public"]['Tables']["monvelo_agents"]['Row'], Database["public"]['Tables']["monvelo_agents"]['ComputedFields']> }; Returns: Json
                           },
"monvelo_agent_day_used":
{ Args: { "p_agent_id": string }; Returns: number
                           },
"monvelo_agent_open_exposure":
{ Args: { "p_agent_id": string }; Returns: number
                           },
"monvelo_agent_register_preflight":
{ Args: { "p_idempotency_key": string,"p_operation": string,"p_request": Json }; Returns: Json
                           },
"monvelo_agents_near":
{ Args: { "p_radius_m"?: number,"p_shop_id": string }; Returns: {
              "agent_id": string,"distance_m": number,"pos_network": Database["public"]['Enums']["pos_network_enum"]
            }[]
                           },
"monvelo_allowance_ceiling":
{ Args: Record<PropertyKey, never>; Returns: number
                           },
"monvelo_apply_declaration_outcome":
{ Args: { "p_actor": string,"p_error": string,"p_id": string,"p_insurer_reference": string,"p_outcome": string }; Returns: Json
                           },
"monvelo_apply_late_charge":
{ Args: { "p_fin": Omit<Database["public"]['Tables']["monvelo_financings"]['Row'], Database["public"]['Tables']["monvelo_financings"]['ComputedFields']> }; Returns: {
              "approval_required": boolean,
"approved_at": string | null,
"approved_by": string | null,
"area_id": string,
"cancel_reason": string | null,
"cancelled_at": string | null,
"cancelled_by": string | null,
"claim_expires_at": string | null,
"claimed_by": string | null,
"claimed_by_agent_id": string | null,
"closed_at": string | null,
"created_at": string,
"delivered_at": string | null,
"due_at": string | null,
"funded_at": string | null,
"funder_agent_id": string | null,
"id": string,
"late_charge_amount": number,
"offered_at": string | null,
"order_id": string,
"outstanding": number | null,
"paystack_reference": string | null,
"pledge_id": string | null,
"preferred_agent_id": string | null,
"preferred_window_ends_at": string | null,
"principal": number,
"raised_by": string,
"reference": string,
"shop_id": string,
"status": string,
"supply_date": string,
"tenant_id": string,
"territory_id": string,
"updated_at": string
            }
                          SetofOptions: {
        from: "monvelo_financings"
        to: "monvelo_financings"
        isOneToOne: true
        isSetofReturn: false
      } },
"monvelo_apply_late_charge_now":
{ Args: { "p_fin": Omit<Database["public"]['Tables']["monvelo_financings"]['Row'], Database["public"]['Tables']["monvelo_financings"]['ComputedFields']> }; Returns: {
              "approval_required": boolean,
"approved_at": string | null,
"approved_by": string | null,
"area_id": string,
"cancel_reason": string | null,
"cancelled_at": string | null,
"cancelled_by": string | null,
"claim_expires_at": string | null,
"claimed_by": string | null,
"claimed_by_agent_id": string | null,
"closed_at": string | null,
"created_at": string,
"delivered_at": string | null,
"due_at": string | null,
"funded_at": string | null,
"funder_agent_id": string | null,
"id": string,
"late_charge_amount": number,
"offered_at": string | null,
"order_id": string,
"outstanding": number | null,
"paystack_reference": string | null,
"pledge_id": string | null,
"preferred_agent_id": string | null,
"preferred_window_ends_at": string | null,
"principal": number,
"raised_by": string,
"reference": string,
"shop_id": string,
"status": string,
"supply_date": string,
"tenant_id": string,
"territory_id": string,
"updated_at": string
            }
                          SetofOptions: {
        from: "monvelo_financings"
        to: "monvelo_financings"
        isOneToOne: true
        isSetofReturn: false
      } },
"monvelo_assert_delivery_day":
{ Args: { "p_fin": Omit<Database["public"]['Tables']["monvelo_financings"]['Row'], Database["public"]['Tables']["monvelo_financings"]['ComputedFields']> }; Returns: undefined
                           },
"monvelo_assert_liquidity_partner":
{ Args: { "p_action": string,"p_agent_id": string }; Returns: undefined
                           },
"monvelo_assign_shop_code":
{ Args: { "p_shop_id": string }; Returns: string
                           },
"monvelo_brand_exposure":
{ Args: { "p_brand_key": string,"p_exclude": string,"p_shop_id": string,"p_tenant_id": string }; Returns: number
                           },
"monvelo_cancel_trade_order":
{ Args: { "p_order_id": string,"p_tenant_id": string }; Returns: number
                           },
"monvelo_claim_hold_rows":
{ Args: { "p_hold_id": string,"p_profile_id": string,"p_tenant_id": string }; Returns: {
              "area_name": string,"blocks": (string)[],"brand_lines": Json,"can_decide": boolean,"decided_at": string,"decided_by_name": string,"expires_at": string,"financing_reference": string,"hold_id": string,"principal": number,"ready": boolean,"reason": string,"shop_code": string,"shop_defaulted": number,"shop_limits": Json,"shop_name": string,"shop_open": number,"shop_repaid_in_window": number,"shop_repaid_late": number,"status": string,"within_limit": boolean
            }[]
                           },
"monvelo_claim_refusal":
{ Args: { "p_agent": Omit<Database["public"]['Tables']["monvelo_agents"]['Row'], Database["public"]['Tables']["monvelo_agents"]['ComputedFields']>,"p_exposure_ceiling"?: number,"p_fin": Omit<Database["public"]['Tables']["monvelo_financings"]['Row'], Database["public"]['Tables']["monvelo_financings"]['ComputedFields']>,"p_late": boolean,"p_member": string,"p_pledge": Omit<Database["public"]['Tables']["monvelo_pledges"]['Row'], Database["public"]['Tables']["monvelo_pledges"]['ComputedFields']> }; Returns: string
                           },
"monvelo_clean_account":
{ Args: { "p_account": Json }; Returns: Json
                           },
"monvelo_covers_area":
{ Args: { "p_area_id": string,"p_me": Omit<Database["public"]['Tables']["tenant_users"]['Row'], Database["public"]['Tables']["tenant_users"]['ComputedFields']> }; Returns: boolean
                           },
"monvelo_declaration_financing":
{ Args: { "p_decl": Omit<Database["public"]['Tables']["monvelo_insurance_declarations"]['Row'], Database["public"]['Tables']["monvelo_insurance_declarations"]['ComputedFields']> }; Returns: string
                           },
"monvelo_delivery_cutoff":
{ Args: { "p_funded_at": string }; Returns: string
                           },
"monvelo_draw_partner_code":
{ Args: Record<PropertyKey, never>; Returns: string
                           },
"monvelo_draw_reference":
{ Args: Record<PropertyKey, never>; Returns: string
                           },
"monvelo_enqueue_declaration":
{ Args: { "p_insurer_id": string,"p_kind": string,"p_payload": Json,"p_subject_id": string,"p_subject_table": string,"p_tenant_id": string }; Returns: string
                           },
"monvelo_fee_bps_at":
{ Args: { "p_date": string,"p_tenant_id": string }; Returns: number
                           },
"monvelo_field_covers_area":
{ Args: { "p_area_id": string,"p_me": Omit<Database["public"]['Tables']["tenant_users"]['Row'], Database["public"]['Tables']["tenant_users"]['ComputedFields']> }; Returns: boolean
                           },
"monvelo_field_partners_near":
{ Args: { "p_radius_m"?: number,"p_shop_id": string }; Returns: {
              "agent_id": string,"business_name": string,"distance_m": number,"partner_code": string,"pos_network": Database["public"]['Enums']["pos_network_enum"]
            }[]
                           },
"monvelo_has_open_storage_claim":
{ Args: { "p_financing_id": string }; Returns: boolean
                           },
"monvelo_hold_market_makers":
{ Args: { "p_agent_id": string,"p_area_id": string,"p_raiser": string,"p_tenant_id": string }; Returns: string[]
                           },
"monvelo_hold_viewers":
{ Args: { "p_agent_id": string,"p_area_id": string,"p_raiser": string,"p_tenant_id": string }; Returns: string[]
                           },
"monvelo_insurer_underwrites":
{ Args: { "p_insurer_id": string }; Returns: boolean
                           },
"monvelo_is_shop_covered":
{ Args: { "p_principal"?: number,"p_shop_id": string,"p_through"?: string }; Returns: boolean
                           },
"monvelo_lock_cover":
{ Args: { "p_quote": Json }; Returns: undefined
                           },
"monvelo_lock_financing":
{ Args: { "p_financing_id": string,"p_me": Omit<Database["public"]['Tables']["tenant_users"]['Row'], Database["public"]['Tables']["tenant_users"]['ComputedFields']> }; Returns: {
              "approval_required": boolean,
"approved_at": string | null,
"approved_by": string | null,
"area_id": string,
"cancel_reason": string | null,
"cancelled_at": string | null,
"cancelled_by": string | null,
"claim_expires_at": string | null,
"claimed_by": string | null,
"claimed_by_agent_id": string | null,
"closed_at": string | null,
"created_at": string,
"delivered_at": string | null,
"due_at": string | null,
"funded_at": string | null,
"funder_agent_id": string | null,
"id": string,
"late_charge_amount": number,
"offered_at": string | null,
"order_id": string,
"outstanding": number | null,
"paystack_reference": string | null,
"pledge_id": string | null,
"preferred_agent_id": string | null,
"preferred_window_ends_at": string | null,
"principal": number,
"raised_by": string,
"reference": string,
"shop_id": string,
"status": string,
"supply_date": string,
"tenant_id": string,
"territory_id": string,
"updated_at": string
            }
                          SetofOptions: {
        from: "*"
        to: "monvelo_financings"
        isOneToOne: true
        isSetofReturn: false
      } },
"monvelo_name_tokens":
{ Args: { "p_name": string }; Returns: (string)[]
                           },
"monvelo_notify_claim":
{ Args: { "p_claim": Omit<Database["public"]['Tables']["monvelo_insurance_claims"]['Row'], Database["public"]['Tables']["monvelo_insurance_claims"]['ComputedFields']> }; Returns: undefined
                           },
"monvelo_notify_hold":
{ Args: { "p_hold_id": string }; Returns: undefined
                           },
"monvelo_notify_hold_decided":
{ Args: { "p_hold_id": string }; Returns: undefined
                           },
"monvelo_offer":
{ Args: { "p_id": string }; Returns: {
              "approval_required": boolean,
"approved_at": string | null,
"approved_by": string | null,
"area_id": string,
"cancel_reason": string | null,
"cancelled_at": string | null,
"cancelled_by": string | null,
"claim_expires_at": string | null,
"claimed_by": string | null,
"claimed_by_agent_id": string | null,
"closed_at": string | null,
"created_at": string,
"delivered_at": string | null,
"due_at": string | null,
"funded_at": string | null,
"funder_agent_id": string | null,
"id": string,
"late_charge_amount": number,
"offered_at": string | null,
"order_id": string,
"outstanding": number | null,
"paystack_reference": string | null,
"pledge_id": string | null,
"preferred_agent_id": string | null,
"preferred_window_ends_at": string | null,
"principal": number,
"raised_by": string,
"reference": string,
"shop_id": string,
"status": string,
"supply_date": string,
"tenant_id": string,
"territory_id": string,
"updated_at": string
            }
                          SetofOptions: {
        from: "*"
        to: "monvelo_financings"
        isOneToOne: true
        isSetofReturn: false
      } },
"monvelo_open_exposure_ceiling":
{ Args: Record<PropertyKey, never>; Returns: number
                           },
"monvelo_open_offers":
{ Args: { "p_agent_id": string }; Returns: {
              "area_name": string,"distance_m": number,"financing_id": string,"preferred_until": string,"principal": number,"reference": string,"shop_code": string,"shop_name": string,"supply_date": string
            }[]
                           },
"monvelo_order_cutoff_at":
{ Args: { "p_supply_date": string }; Returns: string
                           },
"monvelo_order_financing_status":
{ Args: { "p_order_ids": (string)[] }; Returns: {
              "financing_id": string,"financing_state": string,"order_id": string,"principal": number,"reference": string
            }[]
                           },
"monvelo_owner_code_email":
{ Args: { "p_owner_id": string }; Returns: string
                           },
"monvelo_payer_matches":
{ Args: { "p_agent": Omit<Database["public"]['Tables']["monvelo_agents"]['Row'], Database["public"]['Tables']["monvelo_agents"]['ComputedFields']>,"p_verified": Json }; Returns: boolean
                           },
"monvelo_quote_agent_yield":
{ Args: { "p_financing_id": string }; Returns: Json
                           },
"monvelo_raise_flag":
{ Args: { "p_agent_id": string,"p_details": Json,"p_financing_id": string,"p_kind": string }; Returns: string
                           },
"monvelo_record_pairing":
{ Args: { "p_agent_id": string,"p_shop_id": string,"p_source": string,"p_tenant_id": string }; Returns: {
              "agent_id": string,
"area_id": string,
"id": string,
"paired_at": string,
"paired_by": string,
"shop_id": string,
"source": string,
"tenant_id": string,
"unpair_reason": string | null,
"unpaired_at": string | null,
"unpaired_by": string | null
            }
                          SetofOptions: {
        from: "*"
        to: "monvelo_shop_pairings"
        isOneToOne: true
        isSetofReturn: false
      } },
"monvelo_recruitment_request":
{ Args: { "p_args": Json,"p_operation": string }; Returns: Json
                           },
"monvelo_request_supply_date":
{ Args: Record<PropertyKey, never>; Returns: string
                           },
"monvelo_settings":
{ Args: Record<PropertyKey, never>; Returns: {
              "allow_mock_insurers": boolean,
"claim_minutes": number,
"id": boolean,
"offer_radius_m": number,
"order_cutoff_local": string,
"preferred_window_minutes": number,
"supply_lead_days": number,
"updated_at": string
            }
                          SetofOptions: {
        from: "*"
        to: "monvelo_platform_settings"
        isOneToOne: true
        isSetofReturn: false
      } },
"monvelo_settle_claim":
{ Args: { "p_actor": string,"p_claim_id": string,"p_payout_reference": string,"p_settled_amount": number }; Returns: Json
                           },
"monvelo_shop_cover_status":
{ Args: { "p_principal": number,"p_shop_id": string,"p_through": string }; Returns: {
              "policy_id": string,"status": string
            }[]
                           },
"monvelo_shop_limit_for":
{ Args: { "p_brand_key": string,"p_shop_id": string,"p_tenant_id": string }; Returns: {
              "brand_key": string,
"created_at": string,
"limit_amount": number,
"shop_id": string,
"status": string,
"tenant_id": string,
"updated_at": string
            }
                          SetofOptions: {
        from: "*"
        to: "monvelo_shop_limits"
        isOneToOne: true
        isSetofReturn: false
      } },
"monvelo_shop_open_principal":
{ Args: { "p_shop_id": string }; Returns: number
                           },
"monvelo_supply_day_ended":
{ Args: { "p_supply_date": string }; Returns: boolean
                           },
"monvelo_supply_days_near":
{ Args: { "p_agent_id": string,"p_days"?: number }; Returns: {
              "area_id": string,"area_name": string,"shop_count": number,"supply_date": string
            }[]
                           },
"monvelo_sweep_declarations":
{ Args: Record<PropertyKey, never>; Returns: number
                           },
"monvelo_sweep_money":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"monvelo_sweep_offers":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"monvelo_sweep_shop_policies":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"monvelo_tenant_has_csm":
{ Args: { "p_tenant_id": string }; Returns: boolean
                           },
"monvelo_terms_accepted":
{ Args: { "p_agent_id": string,"p_audience": string,"p_tenant_id": string }; Returns: boolean
                           },
"monvelo_terms_at":
{ Args: { "p_at": string,"p_brand": string,"p_tenant_id": string }; Returns: {
              "approval_decision_id": string | null,
"approved_at": string | null,
"approved_by": string | null,
"brand": string,
"brand_key": string | null,
"created_at": string,
"id": string,
"interest_free_days": number,
"late_charge_bps": number,
"proposed_by": string,
"rebate_bps": number,
"status": string,
"tenant_id": string,
"valid_from": string,
"valid_to": string | null
            }
                          SetofOptions: {
        from: "*"
        to: "monvelo_brand_terms"
        isOneToOne: true
        isSetofReturn: false
      } },
"monvelo_terms_body_sha256":
{ Args: { "p_code": string }; Returns: string
                           },
"monvelo_terms_checked":
{ Args: { "p_audience": string,"p_body_sha256": string,"p_code": string }; Returns: {
              "audience": string,
"body": string,
"code": string,
"created_at": string,
"published_at": string | null,
"retired_at": string | null,
"status": string,
"title": string,
"updated_at": string
            }
                          SetofOptions: {
        from: "*"
        to: "monvelo_terms_versions"
        isOneToOne: true
        isSetofReturn: false
      } },
"monvelo_today":
{ Args: Record<PropertyKey, never>; Returns: string
                           },
"monvelo_unpaid_principal":
{ Args: { "p_fin": Omit<Database["public"]['Tables']["monvelo_financings"]['Row'], Database["public"]['Tables']["monvelo_financings"]['ComputedFields']> }; Returns: number
                           },
"my_chat_channel_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_contact_report_hard_copy_paths":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_contact_report_tenant_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_covered_shop_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_delivery_proof_paths":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_fulfilment_order_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_monvelo_agent_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_monvelo_field_agent_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_monvelo_field_area_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_monvelo_nomination_tenant_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_monvelo_policy_shop_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_monvelo_repayment_financing_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_monvelo_staff_tenant_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_monvelo_territory_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_owned_shop_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_peer_profile_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_support_attachment_paths":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_support_history_ticket_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_support_message_ticket_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_support_ticket_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_tenant_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_tenant_ids_with_role":
{ Args: { "p_roles": (Database["public"]['Enums']["tenant_role_enum"])[] }; Returns: string[]
                           },
"my_tenant_ticket_tenant_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_tm_audit_keys":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_tm_territory_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_zsm_monvelo_nomination_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_zsm_out_of_zone_keys":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_zsm_territory_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"my_zsm_zone_ids":
{ Args: Record<PropertyKey, never>; Returns: string[]
                           },
"new_crockford_reference":
{ Args: { "p_prefix": string }; Returns: string
                           },
"nominate_monvelo_agent":
{ Args: { "p_idempotency_key": string,"p_name": string,"p_phone": string,"p_pos_network": Database["public"]['Enums']["pos_network_enum"],"p_shop_id": string }; Returns: Json
                           },
"notify_tenant_zsms":
{ Args: { "p_body": string,"p_kind": string,"p_payload": Json,"p_tenant_id": string,"p_title": string }; Returns: number
                           },
"open_support_ticket":
{ Args: { "p_category": string,"p_customer": Json,"p_idempotency_key": string,"p_kind": string,"p_lga_id": string,"p_message": string,"p_order_paystack_reference": string,"p_order_public_reference": string,"p_secret_hash": string }; Returns: Json
                           },
"open_tenant_ticket":
{ Args: { "p_category": string,"p_idempotency_key": string,"p_message": string,"p_subject": string }; Returns: Json
                           },
"pair_monvelo_shop_agent":
{ Args: { "p_agent_id": string,"p_idempotency_key": string,"p_shop_id": string }; Returns: Json
                           },
"payment_for_monvelo":
{ Args: { "p_payment": Omit<Database["public"]['Tables']["payments"]['Row'], Database["public"]['Tables']["payments"]['ComputedFields']> }; Returns: boolean
                           },
"payment_monvelo_route":
{ Args: { "p_event": string,"p_payment": Omit<Database["public"]['Tables']["payments"]['Row'], Database["public"]['Tables']["payments"]['ComputedFields']>,"p_source": Database["public"]['Enums']["audit_source_enum"] }; Returns: Json
                           },
"pin_policy_refusal":
{ Args: { "p_pin": string }; Returns: string
                           },
"place_trade_order":
{ Args: { "p_idempotency_key": string,"p_lines": Json,"p_shop_id": string,"p_territory_id"?: string }; Returns: Json
                           },
"place_web_order":
{ Args: { "p_accepted_refund_policy": boolean,"p_checkout": Json,"p_client_ip": unknown,"p_code": string,"p_customer": Json,"p_expected_total": number,"p_idempotency_key": string,"p_items": Json,"p_lga_id": string,"p_payment_route": string,"p_phone_verification_token": string,"p_policy_version_tag": string,"p_utm": Json }; Returns: Json
                           },
"pledge_monvelo_funds":
{ Args: { "p_agent_id": string,"p_amount": number,"p_area_id": string,"p_idempotency_key": string,"p_supply_date": string }; Returns: Json
                           },
"pos_order_lookup":
{ Args: { "p_public_reference": string }; Returns: Json
                           },
"post_chat_message":
{ Args: { "p_body": string,"p_channel_id": string,"p_idempotency_key": string }; Returns: Json
                           },
"post_opening_stock":
{ Args: { "p_decision_id": string,"p_idempotency_key": string,"p_items": Json,"p_reference"?: string,"p_warehouse_id": string }; Returns: Json
                           },
"propose_monvelo_brand_terms":
{ Args: { "p_brand": string,"p_idempotency_key": string,"p_interest_free_days": number,"p_late_charge_bps": number,"p_rebate_bps": number,"p_valid_from": string,"p_valid_to": string }; Returns: Json
                           },
"propose_monvelo_insurance_product":
{ Args: { "p_facilitator_fee_bps": number,"p_idempotency_key": string,"p_insurer_id": string,"p_kind": string,"p_rate_bps": number,"p_valid_from": string,"p_valid_to": string }; Returns: Json
                           },
"provision_tenant":
{ Args: { "p_idempotency_key": string,"p_name": string,"p_preferred_code"?: string }; Returns: Json
                           },
"purge_email_outbox":
{ Args: Record<PropertyKey, never>; Returns: number
                           },
"quote_web_order":
{ Args: { "p_code": string,"p_items": Json,"p_lga_id": string }; Returns: Json
                           },
"raise_system_ticket":
{ Args: { "p_body": string,"p_order_id": string,"p_priority": string,"p_system_key": string }; Returns: string
                           },
"read_support_ticket":
{ Args: { "p_public_reference": string,"p_secret": string }; Returns: Json
                           },
"record_monvelo_checkout":
{ Args: { "p_access_code": string,"p_authorization_url": string,"p_gateway_proof": string,"p_idempotency_key": string,"p_payment_id": string }; Returns: Json
                           },
"record_monvelo_claim_settlement":
{ Args: { "p_claim_id": string,"p_idempotency_key": string,"p_payout_reference": string,"p_settled_amount": number }; Returns: Json
                           },
"record_monvelo_declaration_outcome":
{ Args: { "p_declaration_id": string,"p_idempotency_key": string,"p_insurer_reference": string,"p_outcome": string }; Returns: Json
                           },
"record_monvelo_fee_terms":
{ Args: { "p_decision_id": string,"p_fee_bps": number,"p_idempotency_key": string,"p_tenant_id": string,"p_valid_from": string,"p_valid_to": string }; Returns: Json
                           },
"record_monvelo_insurer_event":
{ Args: { "p_event_id": string,"p_insurer_code": string,"p_payload": Json }; Returns: boolean
                           },
"record_monvelo_premium_paid":
{ Args: { "p_idempotency_key": string,"p_payable_id": string,"p_reference": string }; Returns: Json
                           },
"record_monvelo_repayment":
{ Args: { "p_agent_id": string,"p_amount": number,"p_financing_id": string,"p_gateway_proof": string,"p_idempotency_key": string }; Returns: Json
                           },
"record_monvelo_topup_paid":
{ Args: { "p_idempotency_key": string,"p_reference": string,"p_topup_id": string }; Returns: Json
                           },
"record_order_return":
{ Args: { "p_idempotency_key": string,"p_lines": Json,"p_order_id": string }; Returns: Json
                           },
"record_stale_paystack_webhook":
{ Args: { "p_event": string,"p_event_time": string,"p_reference": string }; Returns: Json
                           },
"record_stock_adjustment":
{ Args: { "p_batch_number": string,"p_decision_id": string,"p_idempotency_key": string,"p_quantity_delta": number,"p_reason": string,"p_sku_code": string,"p_warehouse_id": string }; Returns: Json
                           },
"record_stock_receipt":
{ Args: { "p_batch_number": string,"p_decision_id": string,"p_expires_at": string,"p_idempotency_key": string,"p_quantity": number,"p_sku_code": string,"p_warehouse_id": string }; Returns: Json
                           },
"record_stock_transfer":
{ Args: { "p_batch_number": string,"p_decision_id": string,"p_from_warehouse_id": string,"p_idempotency_key": string,"p_quantity": number,"p_sku_code": string,"p_to_warehouse_id": string }; Returns: Json
                           },
"redact_ticket_customer_data":
{ Args: { "p_idempotency_key": string,"p_ticket_id": string }; Returns: Json
                           },
"register_device":
{ Args: { "p_device_model": string,"p_hardware_id": string,"p_idempotency_key": string,"p_push_token": string }; Returns: Json
                           },
"register_monvelo_agent":
{ Args: { "p_agent": Json,"p_gateway_proof": string,"p_idempotency_key": string }; Returns: Json
                           },
"register_monvelo_insurer":
{ Args: { "p_api_provider": string,"p_code": string,"p_idempotency_key": string,"p_legal_name": string,"p_naicom_licence_no": string }; Returns: Json
                           },
"reject_monvelo_repayment":
{ Args: { "p_idempotency_key": string,"p_repayment_id": string }; Returns: Json
                           },
"release_commission":
{ Args: { "p_reference": string,"p_settled_at": string,"p_settlement_id": string,"p_subaccount_share_minor": number }; Returns: Json
                           },
"release_tenant_ticket":
{ Args: { "p_idempotency_key": string,"p_ticket_id": string }; Returns: Json
                           },
"reply_tenant_ticket":
{ Args: { "p_body": string,"p_idempotency_key": string,"p_ticket_id": string }; Returns: Json
                           },
"reply_ticket":
{ Args: { "p_attachment_ids"?: (string)[],"p_body": string,"p_idempotency_key": string,"p_ticket_id": string }; Returns: Json
                           },
"report_monvelo_loss":
{ Args: { "p_description": string,"p_evidence_paths": (string)[],"p_financing_id": string,"p_idempotency_key": string,"p_incident_at": string,"p_kind": string,"p_peril": string }; Returns: Json
                           },
"request_contact_report_hard_copy":
{ Args: { "p_idempotency_key": string,"p_mime_type": string,"p_report_id": string,"p_size_bytes": number }; Returns: Json
                           },
"request_delivery_photo":
{ Args: { "p_idempotency_key": string,"p_mime_type": string,"p_order_id": string,"p_size_bytes": number }; Returns: Json
                           },
"request_monvelo_financing":
{ Args: { "p_idempotency_key": string,"p_order_id": string }; Returns: Json
                           },
"request_monvelo_settlement_change":
{ Args: { "p_account": Json,"p_agent_id": string,"p_gateway_proof": string,"p_idempotency_key": string }; Returns: Json
                           },
"request_staff_ticket_attachment":
{ Args: { "p_idempotency_key": string,"p_mime_type": string,"p_size_bytes": number,"p_ticket_id": string }; Returns: Json
                           },
"request_ticket_attachment":
{ Args: { "p_idempotency_key": string,"p_mime_type": string,"p_public_reference": string,"p_secret": string,"p_size_bytes": number }; Returns: Json
                           },
"requisition_required_level":
{ Args: { "p_sku_codes": (string)[],"p_tenant_id": string }; Returns: Database["public"]['Enums']["tenant_role_enum"]
                           },
"resend_delivery_pin":
{ Args: { "p_gateway_proof": string,"p_idempotency_key": string,"p_order_id": string,"p_pin": string }; Returns: Json
                           },
"resolve_verified_account":
{ Args: { "p_contact": string }; Returns: string
                           },
"review_contact_report":
{ Args: { "p_idempotency_key": string,"p_note"?: string,"p_outcome": string,"p_report_id": string }; Returns: Json
                           },
"review_monvelo_flag":
{ Args: { "p_flag_id": string,"p_idempotency_key": string,"p_note": string }; Returns: Json
                           },
"review_monvelo_shop_policy":
{ Args: { "p_idempotency_key": string,"p_note": string,"p_policy_id": string,"p_verify": boolean }; Returns: Json
                           },
"sees_shared_network":
{ Args: Record<PropertyKey, never>; Returns: boolean
                           },
"set_active_tenant":
{ Args: { "p_idempotency_key": string,"p_tenant_id": string }; Returns: Json
                           },
"set_brand_approval_policy":
{ Args: { "p_brand": string,"p_idempotency_key": string,"p_required_approval_level": Database["public"]['Enums']["tenant_role_enum"] }; Returns: Json
                           },
"set_monvelo_agent_caps":
{ Args: { "p_agent_id": string,"p_daily_cap": number,"p_idempotency_key": string,"p_per_financing_cap": number }; Returns: Json
                           },
"set_monvelo_claim_status":
{ Args: { "p_claim_id": string,"p_idempotency_key": string,"p_insurer_claim_reference": string,"p_status": string }; Returns: Json
                           },
"set_monvelo_insurer_status":
{ Args: { "p_idempotency_key": string,"p_insurer_id": string,"p_status": string }; Returns: Json
                           },
"set_monvelo_supply_day":
{ Args: { "p_active": boolean,"p_area_id": string,"p_day_of_week": number,"p_idempotency_key": string }; Returns: Json
                           },
"set_monvelo_tenant_settings":
{ Args: { "p_approval_cap": number,"p_decision_id"?: string,"p_default_cure_days"?: number,"p_enabled": boolean,"p_idempotency_key": string,"p_limit_growth_bps"?: number,"p_max_limit"?: number,"p_opening_limit": number,"p_post_default_limit_bps"?: number }; Returns: Json
                           },
"set_state_operational":
{ Args: { "p_app_enabled": boolean,"p_idempotency_key": string,"p_reason": string,"p_state_code": string,"p_web_enabled": boolean }; Returns: Json
                           },
"set_tenant_operational_state":
{ Args: { "p_app_enabled": boolean,"p_decision_id": string,"p_idempotency_key": string,"p_state_code": string,"p_web_enabled": boolean }; Returns: Json
                           },
"set_tenant_pin":
{ Args: { "p_idempotency_key": string,"p_new_pin": string }; Returns: Json
                           },
"set_territory_coverage":
{ Args: { "p_idempotency_key": string,"p_lga_id": string,"p_state_code": string,"p_territory_id": string }; Returns: Json
                           },
"set_territory_web_warehouse":
{ Args: { "p_idempotency_key": string,"p_territory_id": string,"p_warehouse_id": string }; Returns: Json
                           },
"set_ticket_priority":
{ Args: { "p_idempotency_key": string,"p_priority": string,"p_ticket_id": string }; Returns: Json
                           },
"set_web_defaults":
{ Args: { "p_agent_id": string,"p_idempotency_key": string,"p_warehouse_id": string }; Returns: Json
                           },
"set_web_pos_venue":
{ Args: { "p_address_text": string,"p_idempotency_key": string,"p_latitude": number,"p_lga": string,"p_longitude": number,"p_operating_hours": Json,"p_state": string,"p_venue_channel": Database["public"]['Enums']["venue_channel_enum"],"p_venue_id": string,"p_venue_name": string }; Returns: Json
                           },
"set_zone_zsm":
{ Args: { "p_idempotency_key": string,"p_profile_id": string,"p_zone_id": string }; Returns: Json
                           },
"settle_monvelo_funding":
{ Args: { "p_amount_minor": number,"p_currency": string,"p_event": string,"p_reference": string,"p_status": string,"p_transaction_id": string,"p_verified": Json }; Returns: Json
                           },
"settle_monvelo_insurance_claim":
{ Args: { "p_claim_reference": string,"p_insurer_code": string,"p_payout_reference": string,"p_settled_amount": number }; Returns: Json
                           },
"settle_paystack_payment":
{ Args: { "p_amount_minor": number,"p_currency": string,"p_event": string,"p_reference": string,"p_split_share_minor": number,"p_split_subaccount": string,"p_status": string,"p_transaction_id": string,"p_verified": Json }; Returns: Json
                           },
"start_monvelo_consent":
{ Args: { "p_area_id": string,"p_gateway_proof": string,"p_idempotency_key": string,"p_shop_id": string }; Returns: Json
                           },
"start_monvelo_delivery":
{ Args: { "p_financing_id": string,"p_gateway_proof": string,"p_idempotency_key": string }; Returns: Json
                           },
"start_monvelo_funding":
{ Args: { "p_agent_id": string,"p_financing_id": string,"p_idempotency_key": string }; Returns: Json
                           },
"start_monvelo_policy_consent":
{ Args: { "p_area_id": string,"p_gateway_proof": string,"p_idempotency_key": string,"p_shop_id": string }; Returns: Json
                           },
"start_web_phone_verification":
{ Args: { "p_client_ip": unknown,"p_code": string,"p_phone": string }; Returns: Json
                           },
"state_app_operational":
{ Args: { "p_state_code": string }; Returns: boolean
                           },
"state_web_operational":
{ Args: { "p_state_code": string }; Returns: boolean
                           },
"stock_assert_sku":
{ Args: { "p_batch_number": string,"p_sku_code": string,"p_tenant_id": string }; Returns: undefined
                           },
"stock_assert_warehouse":
{ Args: { "p_tenant_id": string,"p_warehouse_id": string }; Returns: undefined
                           },
"stock_consume_order":
{ Args: { "p_actor": string,"p_order": Omit<Database["public"]['Tables']["orders"]['Row'], Database["public"]['Tables']["orders"]['ComputedFields']> }; Returns: Json
                           },
"stock_hold_order":
{ Args: { "p_order_id": string,"p_tenant_id": string,"p_until": string }; Returns: number
                           },
"stock_insufficient":
{ Args: { "p_available": number,"p_requested": number,"p_sku": string }; Returns: undefined
                           },
"stock_release_order":
{ Args: { "p_order_id": string,"p_reason": string,"p_tenant_id": string }; Returns: number
                           },
"stock_reservation_sweep":
{ Args: Record<PropertyKey, never>; Returns: number
                           },
"stock_reserve_order":
{ Args: { "p_expires_at": string,"p_order": Omit<Database["public"]['Tables']["orders"]['Row'], Database["public"]['Tables']["orders"]['ComputedFields']> }; Returns: number
                           },
"storage_purge_batch":
{ Args: { "p_limit"?: number }; Returns: Json
                           },
"storage_purge_done":
{ Args: { "p_ids": (string)[] }; Returns: number
                           },
"storefront_catalogue":
{ Args: { "p_code"?: string }; Returns: Json
                           },
"storefront_locations":
{ Args: { "p_code"?: string }; Returns: Json
                           },
"submit_monvelo_shop_policy":
{ Args: { "p_challenge_id": string,"p_code": string,"p_covers_burglary": boolean,"p_covers_fire_perils": boolean,"p_document_path": string,"p_expires_on": string,"p_idempotency_key": string,"p_insurer_name": string,"p_lender_interest_endorsed": boolean,"p_policy_number": string,"p_starts_on": string,"p_sum_insured": number }; Returns: Json
                           },
"support_lock_ticket":
{ Args: { "p_me": Omit<Database["public"]['Tables']["tenant_users"]['Row'], Database["public"]['Tables']["tenant_users"]['ComputedFields']>,"p_ticket_id": string,"p_zsm_only": boolean }; Returns: {
              "accountable_id": string | null,
"assigned_to": string | null,
"category": string,
"created_at": string,
"id": string,
"kind": string,
"last_message_at": string,
"order_id": string | null,
"previous_ticket_id": string | null,
"priority": string,
"public_reference": string,
"resolved_at": string | null,
"status": string,
"system_key": string | null,
"tenant_id": string,
"territory_id": string | null,
"updated_at": string,
"within_damage_window": boolean | null
            }
                          SetofOptions: {
        from: "*"
        to: "support_tickets"
        isOneToOne: true
        isSetofReturn: false
      } },
"support_new_slot":
{ Args: { "p_mime_type": string,"p_size_bytes": number,"p_ticket": Omit<Database["public"]['Tables']["support_tickets"]['Row'], Database["public"]['Tables']["support_tickets"]['ComputedFields']>,"p_uploaded_by": string,"p_uploader_type": string }; Returns: {
              "bucket": string,
"claimed_at": string | null,
"created_at": string,
"id": string,
"message_id": string | null,
"mime_type": string,
"order_id": string | null,
"purpose": string,
"size_bytes": number,
"storage_path": string,
"tenant_id": string,
"ticket_id": string | null,
"uploaded_by": string | null,
"uploaded_by_type": string
            }
                          SetofOptions: {
        from: "*"
        to: "upload_slots"
        isOneToOne: true
        isSetofReturn: false
      } },
"support_notify_activity":
{ Args: { "p_ticket": Omit<Database["public"]['Tables']["support_tickets"]['Row'], Database["public"]['Tables']["support_tickets"]['ComputedFields']> }; Returns: undefined
                           },
"suspend_monvelo_agent":
{ Args: { "p_agent_id": string,"p_idempotency_key": string,"p_reason": string }; Returns: Json
                           },
"tenant_has_csm":
{ Args: { "p_tenant_id": string }; Returns: boolean
                           },
"tenant_role":
{ Args: { "p_tenant_id": string }; Returns: Database["public"]['Enums']["tenant_role_enum"]
                           },
"tenant_state_app_operational":
{ Args: { "p_state_code": string,"p_tenant_id": string }; Returns: boolean
                           },
"tenant_state_web_operational":
{ Args: { "p_state_code": string,"p_tenant_id": string }; Returns: boolean
                           },
"tenant_ticket_caller":
{ Args: Record<PropertyKey, never>; Returns: {
              "is_operator": boolean,"role": Database["public"]['Enums']["tenant_role_enum"]
            }[]
                           },
"tenant_ticket_email":
{ Args: { "p_t": Omit<Database["public"]['Tables']["tenant_support_tickets"]['Row'], Database["public"]['Tables']["tenant_support_tickets"]['ComputedFields']>,"p_template": string }; Returns: undefined
                           },
"tenant_ticket_live_csm":
{ Args: { "p_t": Omit<Database["public"]['Tables']["tenant_support_tickets"]['Row'], Database["public"]['Tables']["tenant_support_tickets"]['ComputedFields']> }; Returns: string
                           },
"tenant_ticket_lock":
{ Args: { "p_operator": boolean,"p_ticket_id": string }; Returns: {
              "assigned_csm_id": string | null,
"category": string,
"created_at": string,
"id": string,
"last_message_at": string,
"opened_by": string,
"priority": string,
"public_reference": string,
"resolved_at": string | null,
"status": string,
"subject": string,
"tenant_id": string,
"updated_at": string
            }
                          SetofOptions: {
        from: "*"
        to: "tenant_support_tickets"
        isOneToOne: true
        isSetofReturn: false
      } },
"tenant_ticket_notify_opener":
{ Args: { "p_t": Omit<Database["public"]['Tables']["tenant_support_tickets"]['Row'], Database["public"]['Tables']["tenant_support_tickets"]['ComputedFields']>,"p_title": string }; Returns: undefined
                           },
"tenant_ticket_notify_teafair":
{ Args: { "p_t": Omit<Database["public"]['Tables']["tenant_support_tickets"]['Row'], Database["public"]['Tables']["tenant_support_tickets"]['ComputedFields']> }; Returns: undefined
                           },
"territory_state_code":
{ Args: { "p_tenant_id": string,"p_territory_id": string }; Returns: string
                           },
"unpair_monvelo_shop_agent":
{ Args: { "p_idempotency_key": string,"p_reason": string,"p_shop_id": string }; Returns: Json
                           },
"update_tenant_ticket_status":
{ Args: { "p_idempotency_key": string,"p_status": string,"p_ticket_id": string }; Returns: Json
                           },
"update_ticket_status":
{ Args: { "p_idempotency_key": string,"p_status": string,"p_ticket_id": string }; Returns: Json
                           },
"upload_slot_extension":
{ Args: { "p_mime_type": string,"p_size_bytes": number }; Returns: string
                           },
"upsert_area":
{ Args: { "p_area_id": string,"p_area_name": string,"p_idempotency_key": string,"p_territory_id": string }; Returns: Json
                           },
"upsert_catalogue_product":
{ Args: { "p_decision_id": string,"p_idempotency_key": string,"p_product": Json }; Returns: Json
                           },
"upsert_tenant_skus":
{ Args: { "p_decision_id": string,"p_idempotency_key": string,"p_items": Json }; Returns: Json
                           },
"upsert_territory":
{ Args: { "p_boundary": Json,"p_idempotency_key": string,"p_territory_id": string,"p_territory_name": string,"p_zone_id": string }; Returns: Json
                           },
"upsert_web_referral_code":
{ Args: { "p_agent_id": string,"p_code": string,"p_discount_type": string,"p_discount_value": number,"p_expires_at": string,"p_idempotency_key": string,"p_is_active": boolean,"p_max_redemptions": number,"p_venue_id": string }; Returns: Json
                           },
"upsert_zone":
{ Args: { "p_boundary": Json,"p_idempotency_key": string,"p_zone_id": string,"p_zone_name": string }; Returns: Json
                           },
"verify_otp":
{ Args: { "p_challenge_id": string,"p_code": string,"p_idempotency_key": string }; Returns: Json
                           },
"verify_pin":
{ Args: { "p_pin": string }; Returns: Database["public"]['CompositeTypes']["pin_check"]
                          SetofOptions: {
        from: "*"
        to: "pin_check"
        isOneToOne: true
        isSetofReturn: false
      } },
"web_active_refund_policy":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"web_category_sellable":
{ Args: { "p_category": string }; Returns: boolean
                           },
"web_codeless_tenant":
{ Args: Record<PropertyKey, never>; Returns: string
                           },
"web_find_order_by_pair":
{ Args: { "p_paystack_reference": string,"p_public_reference": string }; Returns: {
              "agent_id": string | null,
"attributed_agent_id": string | null,
"attributed_venue_id": string | null,
"channel": Database["public"]['Enums']["order_channel_enum"],
"created_at": string,
"delivery_lga_id": string | null,
"discount_amount": number,
"fulfilment_warehouse_id": string | null,
"id": string,
"payment_route": string | null,
"policy_accepted_at": string | null,
"policy_version_tag": string | null,
"public_reference": string | null,
"referral_code_id": string | null,
"retail_shop_id": string | null,
"status": string,
"teafair_agent_id": string,
"tenant_id": string,
"territory_id": string | null,
"total_amount": number,
"tracking_reference": string | null,
"transport_fare": number,
"updated_at": string,
"utm_campaign": string | null,
"utm_medium": string | null,
"utm_source": string | null
            }
                          SetofOptions: {
        from: "*"
        to: "orders"
        isOneToOne: true
        isSetofReturn: false
      } },
"web_order_status":
{ Args: { "p_paystack_reference": string,"p_public_reference": string }; Returns: Json
                           },
"web_price_cart":
{ Args: { "p_code": Omit<Database["public"]['Tables']["web_referral_codes"]['Row'], Database["public"]['Tables']["web_referral_codes"]['ComputedFields']>,"p_items": Json }; Returns: Json
                           },
"web_resolve_code":
{ Args: { "p_code": string }; Returns: {
              "agent_id": string,
"code": string,
"created_at": string,
"created_by": string,
"discount_type": string | null,
"discount_value": number | null,
"expires_at": string | null,
"id": string,
"is_active": boolean,
"max_redemptions": number | null,
"tenant_id": string,
"updated_at": string,
"venue_id": string | null
            }
                          SetofOptions: {
        from: "*"
        to: "web_referral_codes"
        isOneToOne: true
        isSetofReturn: false
      } },
"web_route_order":
{ Args: { "p_code": Omit<Database["public"]['Tables']["web_referral_codes"]['Row'], Database["public"]['Tables']["web_referral_codes"]['ComputedFields']>,"p_lga_id": string,"p_tenant_id": string }; Returns: Database["public"]['CompositeTypes']["web_route"]
                          SetofOptions: {
        from: "*"
        to: "web_route"
        isOneToOne: true
        isSetofReturn: false
      } },
"web_route_try":
{ Args: { "p_code": Omit<Database["public"]['Tables']["web_referral_codes"]['Row'], Database["public"]['Tables']["web_referral_codes"]['ComputedFields']>,"p_lga_id": string,"p_tenant_id": string }; Returns: Database["public"]['CompositeTypes']["web_route"]
                          SetofOptions: {
        from: "*"
        to: "web_route"
        isOneToOne: true
        isSetofReturn: false
      } },
"web_storefront_code":
{ Args: { "p_code": string }; Returns: {
              "agent_id": string,
"code": string,
"created_at": string,
"created_by": string,
"discount_type": string | null,
"discount_value": number | null,
"expires_at": string | null,
"id": string,
"is_active": boolean,
"max_redemptions": number | null,
"tenant_id": string,
"updated_at": string,
"venue_id": string | null
            }
                          SetofOptions: {
        from: "*"
        to: "web_referral_codes"
        isOneToOne: true
        isSetofReturn: false
      } },
"withdraw_monvelo_brand_terms":
{ Args: { "p_decision_id": string,"p_idempotency_key": string,"p_terms_id": string }; Returns: Json
                           },
"withdraw_monvelo_insurance_product":
{ Args: { "p_idempotency_key": string,"p_product_id": string,"p_reason": string }; Returns: Json
                           },
"withdraw_monvelo_shop_consent":
{ Args: { "p_idempotency_key": string,"p_shop_id": string }; Returns: Json
                           },
"withdraw_monvelo_shop_policy":
{ Args: { "p_idempotency_key": string,"p_policy_id": string,"p_reason": string }; Returns: Json
                           },
"write_audit":
{ Args: { "p_after": Json,"p_before": Json,"p_entity_id": string,"p_entity_type": string,"p_idempotency_key": string,"p_operation": string,"p_source"?: Database["public"]['Enums']["audit_source_enum"],"p_teafair_agent_id"?: string,"p_tenant_id": string }; Returns: undefined
                           },
"zone_state_backfill":
{ Args: Record<PropertyKey, never>; Returns: undefined
                           },
"zsm_covers_territory":
{ Args: { "p_profile_id": string,"p_tenant_id": string,"p_territory_id": string }; Returns: boolean
                           },
"zsm_reach_zone_ids":
{ Args: { "p_profile_id": string,"p_tenant_id": string }; Returns: string[]
                           },
"zsm_zone_ids":
{ Args: { "p_profile_id": string,"p_tenant_id": string }; Returns: string[]
                           }
          }
          Enums: {
            "audit_source_enum": "USER"|"SYSTEM"|"WEBHOOK"|"CRON"|"WEB","commission_status_enum": "SPLIT"|"SETTLED"|"DISPUTED","density_category_enum": "HIGH_DENSITY"|"MARKET_SQUARE"|"EVENT_CENTER"|"SUBURBAN","gateway_provider_enum": "PAYSTACK","kyc_status_enum": "UNVERIFIED"|"PENDING"|"VERIFIED"|"REJECTED","order_channel_enum": "ONLINE"|"FIELD_SALES"|"RETAIL","otp_purpose_enum": "PICKUP_CONFIRM"|"POS_SETTLEMENT","payment_status_enum": "INITIATED"|"PROCESSING"|"SUCCESS"|"FAILED"|"REFUNDED","platform_role_enum": "PLATFORM_SUPER_ADMIN"|"MONVELO_OPERATOR"|"MONVELO_FINANCE","pos_network_enum": "MONIEPOINT"|"OPAY"|"PALMPAY","tenant_role_enum": "ZSM"|"TM"|"ASM"|"DSM"|"DSA"|"POS_AGENT"|"RETAIL_SHOP_OWNER"|"ZSA"|"ASA"|"CLIENT_SERVICE_MANAGER"|"TENANT_ADMIN"|"LOGISTICS_MANAGER","tenant_status_enum": "ACTIVE"|"SUSPENDED"|"INACTIVE","tenant_user_status_enum": "ACTIVE"|"INVITED"|"DISABLED","venue_channel_enum": "CHURCH"|"MOSQUE"|"HOSPITAL"|"OFFICE_COMPLEX"|"RESIDENTIAL_ESTATE"|"EDUCATIONAL_INSTITUTION"|"EVENT_CENTER"|"TRANSIT_HUB"|"OPEN_MARKET"|"OTHER","warehouse_kind_enum": "CENTRAL"|"REGIONAL"|"STOCKIST"
          }
          CompositeTypes: {
            "pin_check": {
                        "ok": boolean | null,"attempts_left": number | null,"locked_until": string | null
                      },"web_route": {
                        "territory_id": string | null,"warehouse_id": string | null,"accountable_id": string | null
                      }
          }
        }
}

type DatabaseWithoutInternals = Omit<Database, '__InternalSupabase'>

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
  ? (DefaultSchema["Tables"] & DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
      Row: infer R
    }
    ? R
    : never
  : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Insert: infer I
    }
    ? I
    : never
  : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Update: infer U
    }
    ? U
    : never
  : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never
> = DefaultSchemaEnumNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
  ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
  : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never
> = PublicCompositeTypeNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
  ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
  : never

export const Constants = {
  "graphql_public": {
          Enums: {
            
          }
        },"public": {
          Enums: {
            "audit_source_enum": ["USER", "SYSTEM", "WEBHOOK", "CRON", "WEB"],"commission_status_enum": ["SPLIT", "SETTLED", "DISPUTED"],"density_category_enum": ["HIGH_DENSITY", "MARKET_SQUARE", "EVENT_CENTER", "SUBURBAN"],"gateway_provider_enum": ["PAYSTACK"],"kyc_status_enum": ["UNVERIFIED", "PENDING", "VERIFIED", "REJECTED"],"order_channel_enum": ["ONLINE", "FIELD_SALES", "RETAIL"],"otp_purpose_enum": ["PICKUP_CONFIRM", "POS_SETTLEMENT"],"payment_status_enum": ["INITIATED", "PROCESSING", "SUCCESS", "FAILED", "REFUNDED"],"platform_role_enum": ["PLATFORM_SUPER_ADMIN", "MONVELO_OPERATOR", "MONVELO_FINANCE"],"pos_network_enum": ["MONIEPOINT", "OPAY", "PALMPAY"],"tenant_role_enum": ["ZSM", "TM", "ASM", "DSM", "DSA", "POS_AGENT", "RETAIL_SHOP_OWNER", "ZSA", "ASA", "CLIENT_SERVICE_MANAGER", "TENANT_ADMIN", "LOGISTICS_MANAGER"],"tenant_status_enum": ["ACTIVE", "SUSPENDED", "INACTIVE"],"tenant_user_status_enum": ["ACTIVE", "INVITED", "DISABLED"],"venue_channel_enum": ["CHURCH", "MOSQUE", "HOSPITAL", "OFFICE_COMPLEX", "RESIDENTIAL_ESTATE", "EDUCATIONAL_INSTITUTION", "EVENT_CENTER", "TRANSIT_HUB", "OPEN_MARKET", "OTHER"],"warehouse_kind_enum": ["CENTRAL", "REGIONAL", "STOCKIST"]
          }
        }
} as const
