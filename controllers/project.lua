-- Project controller
-- ==================
--
-- Written by Bernat Romagosa and Michael Ball
--
-- Copyright (C) 2021 by Bernat Romagosa and Michael Ball
--
-- This file is part of Snap Cloud.
--
-- Snap Cloud is free software: you can redistribute it and/or modify
-- it under the terms of the GNU Affero General Public License as
-- published by the Free Software Foundation, either version 3 of
-- the License, or (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU Affero General Public License for more details.
--
-- You should have received a copy of the GNU Affero General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

local util = package.loaded.util
local validate = package.loaded.validate
local db = package.loaded.db
local cached = package.loaded.cached
local yield_error = package.loaded.yield_error
local capture_errors = package.loaded.capture_errors
local db = package.loaded.db
local disk = package.loaded.disk

local Projects = package.loaded.Projects
local FlaggedProjects = package.loaded.FlaggedProjects
local Collections = package.loaded.Collections
local Users = package.loaded.Users

ProjectController = {
    run_query = function (self, query)
        -- query can hold a paginator or an SQL query
        if not self.params.page_number then self.params.page_number = 1 end
        local paginator = Projects:paginated(
                 query ..
                    (self.params.search_term and (db.interpolate_query(
                        ' AND (projectname ILIKE ? OR notes ILIKE ?)',
                        '%' .. self.params.search_term .. '%',
                        '%' .. self.params.search_term .. '%')
                    ) or '') ..
                    ' ORDER BY ' ..
                        (self.params.order or 'firstpublished DESC'),
                {
                    per_page = self.params.items_per_page or 15,
                    fields = self.params.fields or '*'
                }
            )

        if not self.ignore_page_count then
            self.num_pages = paginator:num_pages()
        end

        local items = paginator:get_page(self.params.page_number)
        disk:process_thumbnails(items)
        return items
    end,
    fetch = capture_errors(function (self)
        return ProjectController.run_query(
            self,
            [[WHERE ispublished AND NOT EXISTS(
                SELECT 1 FROM deleted_users WHERE
                username = active_projects.username LIMIT 1)]] ..
                db.interpolate_query(course_name_filter())
        )
    end),
    my_projects = capture_errors(function (self)
        self.params.order = 'lastupdated DESC'
        return ProjectController.run_query(
            self,
            db.interpolate_query('WHERE username = ?', self.session.username)
        )
    end),
    user_projects = capture_errors(function (self)
        self.params.order = 'lastupdated DESC'
        ProjectController.run_query(
            self,
            db.interpolate_query(
                'WHERE ispublished AND username = ? ',
                self.params.username
            )
        )
    end),
    remixes = capture_errors(function (self)
        self.params.order = 'remixes.created DESC'
        self.params.fields =
            'DISTINCT username, projectname, remixes.created'
        ProjectController.run_query(
            self,
            db.interpolate_query(
                [[JOIN remixes
                    ON active_projects.id = remixes.remixed_project_id
                WHERE remixes.original_project_id = ?
                AND ispublic]],
                self.params.project_id
            )
        )
    end),
    flagged_projects = capture_errors(function (self)
        self.params.order = 'flag_count DESC'
        self.params.fields = [[active_projects.id AS id,
            active_projects.projectname AS projectname,
            active_projects.username AS username,
            count(*) AS flag_count]]
        local query = [[INNER JOIN flagged_projects ON
                active_projects.id = flagged_projects.project_id
            WHERE active_projects.ispublic
            GROUP BY active_projects.projectname,
                active_projects.username,
                active_projects.id]]
        self.ignore_page_count = true
        if (self.num_pages == nil) then
            local total_flag_count =
                #(Projects:select(query, {fields = self.params.fields}))
            self.num_pages =
                math.ceil(total_flag_count /
                    (self.params.items_per_page or 15))
        end
        return ProjectController.run_query(self, query)
    end),
    share = capture_errors(function (self)
        local project = Projects:find({ id = self.params.project.id })
        assert_can_share(self, project)
        debug_print('type', project.type)
        project:update({
            lastupdated = db.format_date(),
            lastshared = db.format_date(),
            ispublic = true,
            ispublished = false
        })
        self.params.project = project
        self.project = project
    end),
    unshare = capture_errors(function (self)
        local project = Projects:find({ id = self.params.project.id })
        assert_can_share(self, project)
        project:update({
            lastupdated = db.format_date(),
            ispublic = false,
            ispublished = false
        })
        self.params.project = project
        self.project = project
    end),
    publish = capture_errors(function (self)
        local project = Projects:find({ id = self.params.project.id })
        assert_can_share(self, project)
        project:update({
            lastupdated = db.format_date(),
            firstpublished = project.firstpublished or db.format_date(),
            ispublic = true,
            ispublished = true
        })
        self.params.project = project
        self.project = project
    end),
    unpublish = capture_errors(function (self)
        local project = Projects:find({ id = self.params.project.id })
        assert_can_share(self, project)
        project:update({
            lastupdated = db.format_date(),
            ispublished = false
        })
        self.params.project = project
        self.project = project
    end),
    delete = capture_errors(function (self)
        local project = Projects:find({ id = self.params.project.id })
        assert_can_delete(self, project)

        local username = project.username -- keep it for after deleting it

        if self.params.reason then
            send_mail(
                self.queried_user.email,
                mail_subjects.project_deleted .. project.projectname,
                mail_bodies.project_deleted .. self.current_user.role ..
                    '.</p><p>' .. self.params.reason .. '</p>')
        end

        -- Do not actually delete the project; flag it as deleted.
        if not (project:update({ deleted = db.format_date() })) then
            yield_error('Could not delete project ' ..
                self.params.projectname)
        end

        if username == self.current_user.username then
            return self:build_url('my_projects')
        else
            return self:build_url(
                'user?username=' .. package.loaded.util.escape(username)
            )
        end
    end),
    flag = capture_errors(function (self)
        if self.current_user:isbanned() then yield_error(err.banned) end
        local project = Projects:find({ id = self.params.project.id })
        assert_project_exists(self, project)

        local flag =
            FlaggedProjects:select(
                'WHERE project_id = ? AND flagger_id = ?',
                project.id,
                self.current_user.id
            )[1]

        if flag then yield_error(err.project_already_flagged) end

        FlaggedProjects:create({
            flagger_id = self.current_user.id,
            project_id = project.id,
            reason = self.params.reason,
            notes = self.params.notes
        })

        project.flagged = true
        self.params.project = project
        self.project = project
    end),
    remove_flag = capture_errors(function (self)
        -- Check whether we're removing someone else's flag
        if self.params.flagger then assert_min_role(self, 'reviewer') end

        local project = Projects:find({ id = self.params.project.id })

        local flagger =
            self.params.flagger and
                Users:select('WHERE username = ?', self.params.flagger)[1] or
                self.current_user

        -- flag:delete() fails with an internal Lapis error
        if not db.delete(
                    'flagged_projects',
                    'project_id = ? AND flagger_id = ?',
                    project.id,
                    flagger.id
                ) then
            yield_error(err.project_never_flagged)
        end

        self.params.project = project
        self.project = project
    end)
}
