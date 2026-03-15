# encoding: UTF-8
require 'sketchup.rb'

module MR

  # ==========================================================
  # âœ… LED Groove Tool (V1 Full Path Fix) - Silent Module
  # - No Plugins menu items
  # - No toolbar
  # - Safe to load multiple times
  # - Activation entry: MR::LEDGroove.activate_tool
  # ==========================================================

  module LEDGroove
    # âœ… load guard (prevents redefinition if loaded again)
    unless defined?(LOADED_ONCE)
      LOADED_ONCE = true

      IDENTITY = Geom::Transformation.new
      EPS = 0.2.mm

      DICT = "MR_LED_GROOVE"
      KEYS = {
        margin: "end_margin_cm",
        inset:  "inset_cm",
        width:  "groove_w_cm",
        depth:  "depth_cm"
      }

      def self.activate_tool
        Sketchup.active_model.select_tool(Tool.new)
      end

      class Tool
        def initialize
          @settings = nil
          @asked = false

          @ip = Sketchup::InputPoint.new

          @face = nil
          @ents = nil

          @tr  = IDENTITY   # local -> world (FULL PATH)
          @inv = IDENTITY   # world -> local

          @state = :pick_start

          @start_w = nil
          @curr_w  = nil

          @origin_w = nil
          @axis_long_w  = nil
          @axis_short_w = nil
          @axis_mode = nil  # :long or :short
          @n_w = nil
        end

        # ---------- defaults ----------
        def load_defaults
          [
            Sketchup.read_default(DICT, KEYS[:margin], 0.0).to_f,
            Sketchup.read_default(DICT, KEYS[:inset],  4.0).to_f,
            Sketchup.read_default(DICT, KEYS[:width],  2.0).to_f,
            Sketchup.read_default(DICT, KEYS[:depth],  0.5).to_f
          ]
        end

        def save_defaults(vals)
          Sketchup.write_default(DICT, KEYS[:margin], vals[0].to_f)
          Sketchup.write_default(DICT, KEYS[:inset],  vals[1].to_f)
          Sketchup.write_default(DICT, KEYS[:width],  vals[2].to_f)
          Sketchup.write_default(DICT, KEYS[:depth],  vals[3].to_f)
        end

        # ---------- UI ----------
        def ask_settings
          prompts = [
            "Ù…Ù‚Ø§Ø³ Ø§Ù„Ø­ÙØ± (Ø§ØªØ±ÙƒÙ‡0Ù„Ø­ÙØ± ÙƒØ§Ù…Ù„ Ù„Ù„Ù‚Ø·Ø¹Ù‡)(Ø³Ù…)",
            "Ø¨Ø¯Ø§ÙŠØ© Ø§Ù„Ø­ÙØ± (Ø³Ù…)",
            "Ø¹Ø±Ø¶ Ø§Ù„Ø­ÙØ± (Ø³Ù…)",
            "Ø³Ù‚ÙˆØ· Ø§Ù„Ø­ÙØ± (Ø³Ù…)"
          ]
          defaults = @settings || load_defaults
          input = UI.inputbox(prompts, defaults, "MR | LED Groove (V1)")
          return false unless input
          @settings = input.map(&:to_f)
          save_defaults(@settings)
          true
        end

        def activate
          unless @asked
            ok = ask_settings
            @asked = true
            unless ok
              Sketchup.active_model.select_tool(nil)
              return
            end
          end
          Sketchup.set_status_text("Click A â†’ Drag (Snap) â†’ Click B (Cut) | R ØªØ¹Ø¯ÙŠÙ„ | Esc Ø®Ø±ÙˆØ¬", SB_PROMPT)
        end

        def onKeyDown(key, repeat, flags, view)
          case key
          when 27
            Sketchup.active_model.select_tool(nil)
          when 'R'.ord
            ask_settings
            view.invalidate
          end
        end

        # ---------- FULL PATH TRANSFORM ----------
        def full_path_transformation(path)
          tr = IDENTITY
          arr = path.to_a
          arr.each do |e|
            if e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
              tr = tr * e.transformation
            end
          end
          tr
        rescue
          IDENTITY
        end

        # ---------- picking ----------
        def pick_face_using_inputpoint(view, x, y)
          @face = nil
          @ents = nil
          @tr  = IDENTITY
          @inv = IDENTITY

          @ip.pick(view, x, y)
          ip_face = @ip.face
          return unless ip_face.is_a?(Sketchup::Face)

          ph = view.pick_helper
          ph.do_pick(x, y)

          chosen_path = nil
          chosen_leaf = nil

          (0...ph.count).each do |i|
            pth = ph.path_at(i)
            next unless pth && pth.any?
            arr = pth.to_a
            next unless arr.include?(ip_face)

            leaf = arr.reverse.find { |e| e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }
            next unless leaf

            chosen_path = pth
            chosen_leaf = leaf
            break
          end
          return unless chosen_path && chosen_leaf

          tr = full_path_transformation(chosen_path)
          inv = tr.inverse

          ents = chosen_leaf.is_a?(Sketchup::Group) ? chosen_leaf.entities : chosen_leaf.definition.entities
          return unless ents

          @face = ip_face
          @ents = ents
          @tr  = tr
          @inv = inv
        rescue => e
          puts "pick_face ERROR: #{e.class} - #{e.message}"
        end

        # ---------- geometry helpers (WORLD) ----------
        def compute_axes_world_from_face
          verts_w = @face.outer_loop.vertices.map { |v| v.position.transform(@tr) }
          @origin_w = verts_w.first

          edges = @face.outer_loop.edges
          long_e  = edges.max_by(&:length)
          short_e = edges.min_by(&:length)

          a = long_e.start.position.transform(@tr)
          b = long_e.end.position.transform(@tr)
          v1 = b - a
          @axis_long_w = Geom::Vector3d.new(v1.x, v1.y, v1.z)
          @axis_long_w.normalize!

          c = short_e.start.position.transform(@tr)
          d = short_e.end.position.transform(@tr)
          v2 = d - c
          @axis_short_w = Geom::Vector3d.new(v2.x, v2.y, v2.z)
          @axis_short_w.normalize!

          n_local = @face.normal
          n_w_tmp = n_local.transform(@tr)
          @n_w = Geom::Vector3d.new(n_w_tmp.x, n_w_tmp.y, n_w_tmp.z)
          @n_w.normalize!
        end

        def coord_world(pt_w, axis_w)
          d = pt_w - @origin_w
          Geom::Vector3d.new(d.x, d.y, d.z).dot(axis_w)
        end

        # ---------- mouse ----------
        def onMouseMove(flags, x, y, view)
          @ip.pick(view, x, y)
          return unless @face

          pt_w = @ip.position
          return unless pt_w.is_a?(Geom::Point3d)
          @curr_w = pt_w

          if @state == :drag && @start_w && @axis_long_w && @axis_short_w
            v_drag = @curr_w - @start_w
            return if v_drag.length < 1.mm
            @axis_mode = (v_drag.dot(@axis_long_w).abs > v_drag.dot(@axis_short_w).abs) ? :long : :short
          end

          view.invalidate
        rescue => e
          puts "onMouseMove ERROR: #{e.class} - #{e.message}"
        end

        def onLButtonDown(flags, x, y, view)
          if @state == :pick_start
            pick_face_using_inputpoint(view, x, y)
            return unless @face && @ents

            pt_w = @ip.position
            return unless pt_w.is_a?(Geom::Point3d)
            @start_w = pt_w

            compute_axes_world_from_face
            @axis_mode = nil
            @state = :drag
            return
          end

          if @state == :drag
            return unless @axis_mode
            perform_cut_world
            reset_for_next_cut
            view.invalidate
          end
        rescue => e
          UI.messagebox("Ø®Ø·Ø£:\n#{e.class}\n#{e.message}")
          puts "onLButtonDown ERROR: #{e.class} - #{e.message}"
        end

        def reset_for_next_cut
          @face = nil
          @ents = nil
          @tr  = IDENTITY
          @inv = IDENTITY
          @state = :pick_start
          @start_w = nil
          @curr_w  = nil
          @origin_w = nil
          @axis_long_w = @axis_short_w = nil
          @axis_mode = nil
          @n_w = nil
        end

        # ---------- draw ----------
        def draw(view)
          return unless @state == :drag && @axis_mode && @start_w && @axis_long_w && @axis_short_w
          axis = (@axis_mode == :long) ? @axis_long_w : @axis_short_w

          a = @start_w
          b = Geom::Point3d.new(
            @start_w.x + axis.x * 140.mm,
            @start_w.y + axis.y * 140.mm,
            @start_w.z + axis.z * 140.mm
          )

          view.line_width = 3
          view.drawing_color = "black"
          view.draw(GL_LINES, [a, b])
        rescue => e
          puts "draw ERROR: #{e.class} - #{e.message}"
        end

        # ---------- CUT (WORLD accurate) ----------
        def perform_cut_world
          return unless @settings && @face && @ents && @start_w

          end_margin_w = @settings[0].to_f.cm
          inset_w      = @settings[1].to_f.cm
          groove_w_w   = @settings[2].to_f.cm
          depth_w      = @settings[3].to_f.cm

          verts_w = @face.outer_loop.vertices.map { |v| v.position.transform(@tr) }

          axis = (@axis_mode == :long) ? @axis_long_w : @axis_short_w
          perp = (@axis_mode == :long) ? @axis_short_w : @axis_long_w

          a_vals = verts_w.map { |pt| coord_world(pt, axis) }
          a_min, a_max = a_vals.minmax
          full_len = (a_max - a_min).abs
          end_margin_w = 0.0 if full_len - (2.0 * end_margin_w) < 2.mm
          a_min += end_margin_w
          a_max -= end_margin_w

          b_vals = verts_w.map { |pt| coord_world(pt, perp) }
          b_min, b_max = b_vals.minmax
          full_w = (b_max - b_min).abs
          groove_w_w = [groove_w_w, full_w - 2.mm].min
          groove_w_w = 1.mm if groove_w_w < 1.mm

          pick_b = coord_world(@start_w, perp)
          dist_to_min = (pick_b - b_min).abs
          dist_to_max = (b_max - pick_b).abs
          boundary = (dist_to_min <= dist_to_max) ? b_min : b_max

          cx = cy = cz = 0.0
          verts_w.each { |p| cx += p.x; cy += p.y; cz += p.z }
          center_w = Geom::Point3d.new(cx/verts_w.length, cy/verts_w.length, cz/verts_w.length)
          center_b = coord_world(center_w, perp)
          inward_sign = (center_b >= boundary) ? +1.0 : -1.0

          available =
            if inward_sign > 0
              (b_max - boundary) - groove_w_w - EPS
            else
              (boundary - b_min) - groove_w_w - EPS
            end
          available = 0.0 if available < 0.0

          inset = inset_w
          inset = 0.0 if inset < 0.0
          inset = available if inset > available

          b1 = boundary + inward_sign * inset
          b2 = b1 + inward_sign * groove_w_w

          pw = lambda do |t, s|
            Geom::Point3d.new(
              @origin_w.x + axis.x * t + perp.x * s,
              @origin_w.y + axis.y * t + perp.y * s,
              @origin_w.z + axis.z * t + perp.z * s
            )
          end

          p1_w = pw.call(a_min, b1)
          p2_w = pw.call(a_max, b1)
          p3_w = pw.call(a_max, b2)
          p4_w = pw.call(a_min, b2)

          p1 = p1_w.transform(@inv)
          p2 = p2_w.transform(@inv)
          p3 = p3_w.transform(@inv)
          p4 = p4_w.transform(@inv)

          n_local = @face.normal
          n_local_u = Geom::Vector3d.new(n_local.x, n_local.y, n_local.z)
          n_local_u.normalize!
          n_w_vec = n_local_u.transform(@tr)
          s_n = n_w_vec.length
          s_n = 1.0 if s_n < 1e-9
          depth_local = depth_w / s_n

          model = Sketchup.active_model
          model.start_operation("MR - LED Groove (V1)", true)

          groove_face = @ents.add_face(p1, p2, p3, p4)
          if groove_face && groove_face.valid?
            begin
              groove_face.pushpull(-depth_local)
            rescue
              groove_face.reverse!
              groove_face.pushpull(-depth_local)
            end
          end

          model.commit_operation
        rescue => e
          Sketchup.active_model.abort_operation rescue nil
          UI.messagebox("Ø®Ø·Ø£ Ø£Ø«Ù†Ø§Ø¡ Ø§Ù„Ù‚Ø·Ø¹:\n#{e.class}\n#{e.message}")
          puts "perform_cut ERROR: #{e.class} - #{e.message}"
        end
      end

    end # LOADED_ONCE guard
  end # LEDGroove

end # MR
