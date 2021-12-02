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

local Projects = package.loaded.Projects
local Collections = package.loaded.Collections
local Users = package.loaded.Users
local db = package.loaded.db
local disk = package.loaded.disk

ProjectController = {
    run_query = function (self, query)
        -- query can hold a paginator or an SQL query
        local paginator = Projects:paginated(
                 query ..
                    (self.params.data.search_term and (db.interpolate_query(
                        ' AND (projectname ILIKE ? OR notes ILIKE ?)',
                        '%' .. self.params.data.search_term .. '%',
                        '%' .. self.params.data.search_term .. '%')
                    ) or '') ..
                    ' ORDER BY ' ..
                        (self.params.data.order or 'firstpublished DESC'),
                {
                    per_page = self.params.data.per_page or 15,
                    fields = self.params.data.fields or '*'
                }
            )

        if not self.params.data.ignore_page_count then
            self.params.data.num_pages = paginator:num_pages()
        end

        self.items = paginator:get_page(self.params.data.page_number)
        disk:process_thumbnails(self.items)
        self.data = self.params.data
    end,
    change_page = function (self)
        if self.params.offset == 'first' then
            self.params.data.page_number = 1
        elseif self.params.offset == 'last' then
            self.params.data.page_number = self.params.data.num_pages
        else
            self.params.data.page_number = 
                math.min(
                    math.max(
                        1,
                        self.params.data.page_number + self.params.offset),
                    self.params.data.num_pages)
        end
        ProjectController[self.component.fetch_selector](self)
    end,
    fetch = function (self)
        ProjectController.run_query(
            self,
            [[WHERE ispublished AND NOT EXISTS(
                SELECT 1 FROM deleted_users WHERE
                username = active_projects.username LIMIT 1)]] ..
                db.interpolate_query(course_name_filter())
        )
    end,
    search = function (self)
        self.params.data.search_term = self.params.search_term
        ProjectController[self.component.fetch_selector](self)
    end,
    my_projects = function (self)
        self.params.data.order = 'lastupdated DESC'
        ProjectController.run_query(
            self,
            db.interpolate_query('WHERE username = ?', self.session.username)
        )
    end,
    user_projects = function (self)
        self.params.data.order = 'lastupdated DESC'
        ProjectController.run_query(
            self,
            db.interpolate_query(
                'WHERE ispublished AND username = ? ',
                self.params.data.username
            )
        )
    end,
    remixes = function (self)
        self.params.data.order = 'remixes.created DESC'
        self.params.data.fields =
            'DISTINCT username, projectname, remixes.created'
        ProjectController.run_query(
            self,
            db.interpolate_query(
                [[JOIN remixes
                    ON active_projects.id = remixes.remixed_project_id
                WHERE remixes.original_project_id = ?
                AND ispublic]],
                self.params.data.project_id
            )
        )
    end,
    flagged_projects = function (self)
        self.params.data.order = 'flag_count DESC'
        self.params.data.fields = [[active_projects.id AS id,
            active_projects.projectname AS projectname,
            active_projects.username AS username,
            count(*) AS flag_count]]
        local query = [[INNER JOIN flagged_projects ON
                active_projects.id = flagged_projects.project_id
            WHERE active_projects.ispublic
            GROUP BY active_projects.projectname,
                active_projects.username,
                active_projects.id]]
        if (self.params.num_pages == nil) then
            local total_flag_count =
                table.getn(
                    Projects:select(query, {fields = self.params.data.fields})
                )
            self.params.data.num_pages =
                math.ceil(total_flag_count / (self.params.data.per_page or 15))
        end
        ProjectController.run_query(self, query)
    end,
}
