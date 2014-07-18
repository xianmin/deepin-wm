//
//  Copyright (C) 2014 Tom Beckmann
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

using Clutter;
using Meta;

namespace Gala
{
	/**
	 * The central class for the MultitaskingView which takes care of
	 * preparing the wm, opening the components and holds containers for
	 * the icon groups, the WorkspaceClones and the MonitorClones.
	 */
	public class MultitaskingView : Actor
	{
		const int HIDING_DURATION = 300;
		const int SMOOTH_SCROLL_DELAY = 500;

		public WindowManager wm { get; construct; }

		Meta.Screen screen;
		bool opened = false;
		bool animating = false;

		bool is_smooth_scrolling = false;

		List<MonitorClone> window_containers_monitors;

		IconGroupContainer icon_groups;
		Actor workspaces;

		public MultitaskingView (WindowManager wm)
		{
			Object (wm: wm);
		}

		construct
		{
			visible = false;
			reactive = true;
			clip_to_allocation = true;

			opened = false;
			screen = wm.get_screen ();

			workspaces = new Actor ();
			workspaces.set_easing_mode (AnimationMode.EASE_OUT_QUAD);

			icon_groups = new IconGroupContainer (screen);
			icon_groups.request_reposition.connect (() => reposition_icon_groups (true));

			add_child (icon_groups);
			add_child (workspaces);

			foreach (var workspace in screen.get_workspaces ())
				add_workspace (workspace.index ());

			screen.workspace_added.connect (add_workspace);
			screen.workspace_removed.connect (remove_workspace);
			screen.workspace_switched.connect_after ((from, to, direction) => {
				update_positions (opened);
			});

			window_containers_monitors = new List<MonitorClone> ();
			update_monitors ();
			screen.monitors_changed.connect (update_monitors);

			Prefs.add_listener ((pref) => {
				if (pref == Preference.WORKSPACES_ONLY_ON_PRIMARY) {
					update_monitors ();
					return;
				}

				if (Prefs.get_dynamic_workspaces () ||
					(pref != Preference.DYNAMIC_WORKSPACES && pref != Preference.NUM_WORKSPACES))
					return;

				Idle.add (() => {
					unowned List<Workspace> existing_workspaces = screen.get_workspaces ();

					foreach (var child in workspaces.get_children ()) {
						unowned WorkspaceClone workspace_clone = (WorkspaceClone) child;
						if (existing_workspaces.index (workspace_clone.workspace) < 0) {
							workspace_clone.window_selected.disconnect (window_selected);
							workspace_clone.selected.disconnect (activate_workspace);

							icon_groups.remove_group (workspace_clone.icon_group);

							workspace_clone.destroy ();
						}
					}

					update_monitors ();
					update_positions (false);

					return false;
				});
			});
		}

		/**
		 * Places the primary container for the WorkspaceClones and the
		 * MonitorClones at the right positions
		 */
		void update_monitors ()
		{
			foreach (var monitor_clone in window_containers_monitors)
				monitor_clone.destroy ();

			var primary = screen.get_primary_monitor ();

			if (InternalUtils.workspaces_only_on_primary ()) {
				for (var monitor = 0; monitor < screen.get_n_monitors (); monitor++) {
					if (monitor == primary)
						continue;

					var monitor_clone = new MonitorClone (screen, monitor);
					monitor_clone.window_selected.connect (window_selected);
					monitor_clone.visible = opened;

					window_containers_monitors.append (monitor_clone);
					wm.ui_group.add_child (monitor_clone);
				}
			}

			var primary_geometry = screen.get_monitor_geometry (primary);

			set_position (primary_geometry.x, primary_geometry.y);
			set_size (primary_geometry.width, primary_geometry.height);
		}

		/**
		 * We generally assume that when the key-focus-out signal is emitted
		 * a different component was opened, so we close in that case.
		 */
		public override void key_focus_out ()
		{
			if (opened && !contains (get_stage ().key_focus))
				toggle ();
		}

		/**
		 * Scroll through workspaces
		 */
		public override bool scroll_event (ScrollEvent scroll_event)
		{
			if (scroll_event.direction != ScrollDirection.SMOOTH)
				return false;

			double dx, dy;
			var event = (Event*)(&scroll_event);
			event->get_scroll_delta (out dx, out dy);

			var direction = MotionDirection.LEFT;

			// concept from maya to detect mouse wheel and proper smooth scroll and prevent
			// too much repetition on the events
			if (Math.fabs (dy) == 1.0) {
				// mouse wheel scroll
				direction = dy > 0 ? MotionDirection.RIGHT : MotionDirection.LEFT;
			} else if (!is_smooth_scrolling) {
				// actual smooth scroll
				var choice = Math.fabs (dx) > Math.fabs (dy) ? dx : dy;

				if (choice > 0.3)
					direction = MotionDirection.RIGHT;
				else if (choice < -0.3)
					direction = MotionDirection.LEFT;
				else
					return false;

				is_smooth_scrolling = true;
				Timeout.add (SMOOTH_SCROLL_DELAY, () => {
					is_smooth_scrolling = false;
					return false;
				});
			} else
				// smooth scroll delay still active
				return false;

			var active_workspace = screen.get_active_workspace ();
			var new_workspace = active_workspace.get_neighbor (direction);

			if (active_workspace != new_workspace)
				new_workspace.activate (screen.get_display ().get_current_time ());

			return false;
		}

		/**
		 * Places the WorkspaceClones, moves the view so that the active one is shown
		 * and does the same for the IconGroups.
		 *
		 * @param animate Whether to animate the movement or have all elements take their
		 *                positions immediately.
		 */
		void update_positions (bool animate)
		{
			var active_index = screen.get_active_workspace ().index ();
			var active_x = 0.0f;

			foreach (var child in workspaces.get_children ()) {
				unowned WorkspaceClone workspace_clone = (WorkspaceClone) child;
				var index = workspace_clone.workspace.index ();
				var dest_x = index * (workspace_clone.width - 150);

				if (index == active_index) {
					active_x = dest_x;
					workspace_clone.active = true;
				} else {
					workspace_clone.active = false;
				}

				workspace_clone.set_easing_duration (animate ? 200 : 0);
				workspace_clone.x = dest_x;
			}

			workspaces.set_easing_duration (animate ? 300 : 0);
			workspaces.x = -active_x;

			reposition_icon_groups (animate);
		}

		void reposition_icon_groups (bool animate)
		{
			var active_index = screen.get_active_workspace ().index ();

			if (animate) {
				icon_groups.save_easing_state ();
				icon_groups.set_easing_mode (AnimationMode.EASE_OUT_QUAD);
				icon_groups.set_easing_duration (200);
			}

			// make sure the active workspace's icongroup is always visible
			var icon_groups_width = icon_groups.calculate_total_width ();
			if (icon_groups_width > width) {
				icon_groups.x = (-active_index * (IconGroupContainer.SPACING + IconGroup.SIZE) + width / 2)
					.clamp (width - icon_groups_width - 64, 64);
			} else
				icon_groups.x = width / 2 - icon_groups_width / 2;

			if (animate)
				icon_groups.restore_easing_state ();
		}

		void add_workspace (int num)
		{
			var workspace = new WorkspaceClone (screen.get_workspace_by_index (num));
			workspace.window_selected.connect (window_selected);
			workspace.selected.connect (activate_workspace);

			workspaces.insert_child_at_index (workspace, num);
			icon_groups.add_group (workspace.icon_group);

			update_positions (opened);

			if (opened)
				workspace.open ();
		}

		void remove_workspace (int num)
		{
			WorkspaceClone? workspace = null;

			// FIXME is there a better way to get the removed workspace?
			unowned List<Meta.Workspace> existing_workspaces = screen.get_workspaces ();

			foreach (var child in workspaces.get_children ()) {
				unowned WorkspaceClone clone = (WorkspaceClone) child;
				if (existing_workspaces.index (clone.workspace) < 0) {
					workspace = clone;
					break;
				}
			}

			if (workspace == null)
				return;

			workspace.window_selected.disconnect (window_selected);
			workspace.selected.disconnect (activate_workspace);

			icon_groups.remove_group (workspace.icon_group);

			workspace.destroy ();

			update_positions (opened);
		}

		/**
		 * Activates the workspace of a WorkspaceClone
		 *
		 * @param close_view Whether to close the view as well. Will only be considered
		 *                   if the workspace is also the currently active workspace.
		 *                   Otherwise it will only be made active, but the view won't be
		 *                   closed.
		 */
		void activate_workspace (WorkspaceClone clone, bool close_view)
		{
			close_view = close_view && screen.get_active_workspace () == clone.workspace;

			clone.workspace.activate (screen.get_display ().get_current_time ());

			if (close_view)
				toggle ();
		}

		/**
		 * Collect key events, mainly for redirecting them to the WindowCloneContainers to
		 * select the active window.
		 */
		public override bool key_press_event (Clutter.KeyEvent event)
		{
			switch (event.keyval) {
				case Clutter.Key.Escape:
					if (opened)
						toggle ();
					break;
				case Clutter.Key.Down:
					select_window (MotionDirection.DOWN);
					break;
				case Clutter.Key.Up:
					select_window (MotionDirection.UP);
					break;
				case Clutter.Key.Left:
					select_window (MotionDirection.LEFT);
					break;
				case Clutter.Key.Right:
					select_window (MotionDirection.RIGHT);
					break;
				case Clutter.Key.Return:
				case Clutter.Key.KP_Enter:
					get_active_workspace_clone ().window_container.activate_selected_window ();
					break;
			}

			return false;
		}

		/**
		 * Inform the current WindowCloneContainer that we want to move the focus in
		 * a specific direction.
		 *
		 * @param direction The direction in which to move the focus to
		 */
		void select_window (MotionDirection direction)
		{
			get_active_workspace_clone ().window_container.select_next_window (direction);
		}

		/**
		 * Finds the active WorkspaceClone
		 *
		 * @return The active WorkspaceClone
		 */
		WorkspaceClone get_active_workspace_clone ()
		{
			foreach (var child in workspaces.get_children ()) {
				unowned WorkspaceClone workspace_clone = (WorkspaceClone) child;
				if (workspace_clone.workspace == screen.get_active_workspace ()) {
					return workspace_clone;
				}
			}

			assert_not_reached ();
		}

		void window_selected (Meta.Window window)
		{
			var time = screen.get_display ().get_current_time ();
			var workspace = window.get_workspace ();

			if (workspace != screen.get_active_workspace ())
				workspace.activate (time);
			else {
				window.activate (time);
				toggle ();
			}
		}

		/**
		 * Toggles the view open or closed. Takes care of all the wm related tasks, like
		 * starting the modal mode and hiding the WindowGroup. Finally tells all components
		 * to animate to their positions.
		 */
		public void toggle ()
		{
			if (animating)
				return;

			animating = true;

			opened = !opened;
			var opening = opened;

			foreach (var container in window_containers_monitors) {
				if (opening) {
					container.visible = true;
					container.open ();
				} else
					container.close ();
			}

			if (opening) {
				wm.begin_modal ();
				wm.block_keybindings_in_modal = false;

				wm.background_group.hide ();
				wm.window_group.hide ();
				wm.top_window_group.hide ();
				show ();
				grab_key_focus ();

				icon_groups.y = height - WorkspaceClone.BOTTOM_OFFSET + 20;
			} else {
				DragDropAction.cancel_all_by_id ("multitaskingview-window");
			}

			// find active workspace clone and raise it, so there are no overlaps while transitioning
			WorkspaceClone? active_workspace = null;
			var active = screen.get_active_workspace ();
			foreach (var child in workspaces.get_children ()) {
				unowned WorkspaceClone workspace = (WorkspaceClone) child;
				if (workspace.workspace == active) {
					active_workspace = workspace;
					break;
				}
			}
			if (active_workspace != null)
				workspaces.set_child_above_sibling (active_workspace, null);

			update_positions (false);

			foreach (var child in workspaces.get_children ()) {
				unowned WorkspaceClone workspace = (WorkspaceClone) child;
				if (opening)
					workspace.open ();
				else
					workspace.close ();
			}

			if (!opening) {
				Timeout.add (290, () => {
					foreach (var container in window_containers_monitors) {
						container.visible = false;
					}

					hide ();

					wm.background_group.show ();
					wm.window_group.show ();
					wm.top_window_group.show ();

					wm.block_keybindings_in_modal = true;
					wm.end_modal ();

					animating = false;

					return false;
				});
			} else {
				Timeout.add (200, () => {
					animating = false;
					return false;
				});
			}
		}
	}
}

