{-# LANGUAGE TupleSections, OverloadedStrings #-}

module Handler.Project where

import Import

import Model.Currency
import Model.Project
import Model.Shares
import Model.Markdown
import Model.Markdown.Diff
import Model.User
import View.PledgeButton
import Widgets.Markdown
import Widgets.Preview
import Widgets.Time

import           Data.List       (sort)
import qualified Data.Map        as M
import           Data.Maybe      (fromJust, maybeToList)
import qualified Data.Text       as T
import           Data.Time.Clock
import qualified Data.Set        as S
import           Yesod.Markdown

lookupGetParamDefault :: Read a => Text -> a -> Handler a
lookupGetParamDefault name def = do
    maybe_value <- lookupGetParam name
    return $ fromMaybe def $ maybe_value >>= readMaybe . T.unpack

getProjectsR :: Handler Html
getProjectsR = do
    projects <- runDB getAllProjects

    defaultLayout $ do
        setTitle "Projects | Snowdrift.coop"
        $(widgetFile "projects")

getProjectPledgeButtonR :: Text -> Handler TypedContent
getProjectPledgeButtonR project_handle = do
   pledges <- runYDB $ do
        Entity project_id _project <- getBy404 $ UniqueProjectHandle project_handle
        getProjectShares project_id
   let png = overlayImage blankPledgeButton $
        fillInPledgeCount (fromIntegral (length pledges))
   respond "image/png" png

getProjectR :: Text -> Handler Html
getProjectR project_handle = do
    maybe_viewer_id <- maybeAuthId

    (project_id, project, pledges, pledge) <- runYDB $ do
        Entity project_id project <- getBy404 $ UniqueProjectHandle project_handle
        pledges <- getProjectShares project_id
        pledge <- case maybe_viewer_id of
            Nothing -> return Nothing
            Just viewer_id -> getBy $ UniquePledge viewer_id project_id

        return (project_id, project, pledges, pledge)

    defaultLayout $ do
        setTitle . toHtml $ projectName project <> " | Snowdrift.coop"
        renderProject (Just project_id) project pledges pledge


renderProject :: Maybe ProjectId
              -> Project
              -> [Int64]
              -> Maybe (Entity Pledge)
              -> WidgetT App IO ()
renderProject maybe_project_id project pledges pledge = do
    let share_value = projectShareValue project
        users = fromIntegral $ length pledges
        shares = sum pledges
        project_value = share_value $* fromIntegral shares
        description = markdownWidget (projectHandle project) $ projectDescription project

        maybe_shares = pledgeShares . entityVal <$> pledge

    now <- liftIO getCurrentTime

    amounts <- case projectLastPayday project of
        Nothing -> return Nothing
        Just last_payday -> handlerToWidget $ runDB $ do
            -- This assumes there were transactions associated with the last payday
            [Value (Just last) :: Value (Maybe Rational)] <-
                select $
                from $ \ transaction -> do
                where_ $
                    transaction ^. TransactionPayday ==. val (Just last_payday) &&.
                    transaction ^. TransactionCredit ==. val (Just $ projectAccount project)
                return $ sum_ $ transaction ^. TransactionAmount

            [Value (Just year) :: Value (Maybe Rational)] <-
                select $
                from $ \ (transaction `InnerJoin` payday) -> do
                where_ $
                    payday ^. PaydayDate >. val (addUTCTime (-365 * 24 * 60 * 60) now) &&.
                    transaction ^. TransactionCredit ==. val (Just $ projectAccount project)
                on_ $ transaction ^. TransactionPayday ==. just (payday ^. PaydayId)
                return $ sum_ $ transaction ^. TransactionAmount

            [Value (Just total) :: Value (Maybe Rational)] <-
                select $
                from $ \ transaction -> do
                where_ $ transaction ^. TransactionCredit ==. val (Just $ projectAccount project)
                return $ sum_ $ transaction ^. TransactionAmount

            return $ Just (Milray $ round last, Milray $ round year, Milray $ round total)


    ((_, update_shares), _) <- handlerToWidget $ generateFormGet $ maybe previewPledgeForm pledgeForm maybe_project_id

    $(widgetFile "project")


data UpdateProject = UpdateProject { updateProjectName :: Text, updateProjectDescription :: Markdown, updateProjectTags :: [Text], updateProjectGithubRepo :: Maybe Text } deriving Show


editProjectForm :: Maybe (Project, [Text]) -> Form UpdateProject
editProjectForm project =
    renderBootstrap3 $ UpdateProject
        <$> areq' textField "Project Name" (projectName . fst <$> project)
        <*> areq' snowdriftMarkdownField "Description" (projectDescription . fst <$> project)
        <*> (maybe [] (map T.strip . T.splitOn ",") <$> aopt' textField "Tags" (Just . T.intercalate ", " . snd <$> project))
        <*> aopt' textField "Github Repository" (projectGithubRepo . fst <$> project)


getEditProjectR :: Text -> Handler Html
getEditProjectR project_handle = do
    viewer_id <- requireAuthId

    Entity project_id project <- runYDB $ do
        can_edit <- (||) <$> isProjectAdmin project_handle viewer_id <*> isProjectAdmin "snowdrift" viewer_id
        if can_edit
         then getBy404 $ UniqueProjectHandle project_handle
         else permissionDenied "You do not have permission to edit this project."

    tags <- runDB $
        select $
        from $ \ (p_t `InnerJoin` tag) -> do
        on_ (p_t ^. ProjectTagTag ==. tag ^. TagId)
        where_ (p_t ^. ProjectTagProject ==. val project_id)
        return tag

    (project_form, _) <- generateFormPost $ editProjectForm (Just (project, map (tagName . entityVal) tags))

    defaultLayout $ do
        setTitle . toHtml $ projectName project <> " | Snowdrift.coop"
        $(widgetFile "edit_project")


postProjectR :: Text -> Handler Html
postProjectR project_handle = do
    viewer_id <- requireAuthId

    Entity project_id project <- runYDB $ do
        can_edit <- (||) <$> isProjectAdmin project_handle viewer_id <*> isProjectAdmin "snowdrift" viewer_id
        if can_edit
         then getBy404 $ UniqueProjectHandle project_handle
         else permissionDenied "You do not have permission to edit this project."

    ((result, _), _) <- runFormPost $ editProjectForm Nothing

    now <- liftIO getCurrentTime

    case result of
        FormSuccess (UpdateProject name description tags github_repo) -> do
            mode <- lookupPostParam "mode"
            let action :: Text = "update"
            case mode of
                Just "preview" -> do
                    let preview_project = project { projectName = name, projectDescription = description, projectGithubRepo = github_repo }

                    (form, _) <- generateFormPost $ editProjectForm (Just (preview_project, tags))
                    defaultLayout $ previewWidget form action $ renderProject (Just project_id) preview_project [] Nothing

                Just x | x == action -> do
                    runDB $ do
                        when (projectDescription project /= description) $ do
                            project_update <- insert $ ProjectUpdate now project_id viewer_id $ diffMarkdown (projectDescription project) description
                            last_update <- getBy $ UniqueProjectLastUpdate project_id
                            case last_update of
                                Just (Entity key _) -> repsert key $ ProjectLastUpdate project_id project_update
                                Nothing -> void $ insert $ ProjectLastUpdate project_id project_update

                        update $ \ p -> do
                            set p [ ProjectName =. val name, ProjectDescription =. val description, ProjectGithubRepo =. val github_repo ]
                            where_ (p ^. ProjectId ==. val project_id)

                        tag_ids <- forM tags $ \ tag_name -> do
                            tag_entity_list <- select $ from $ \ tag -> do
                                where_ (tag ^. TagName ==. val tag_name)
                                return tag

                            case tag_entity_list of
                                [] -> insert $ Tag tag_name
                                Entity tag_id _ : _ -> return tag_id


                        delete $ from $ \ project_tag -> where_ (project_tag ^. ProjectTagProject ==. val project_id)

                        forM_ tag_ids $ \ tag_id -> insert $ ProjectTag project_id tag_id

                    addAlert "success" "project updated"
                    redirect $ ProjectR project_handle

                _ -> do
                    addAlertEm "danger" "unrecognized mode" "Error: "
                    redirect $ ProjectR project_handle
        x -> do
            addAlert "danger" $ T.pack $ show x
            redirect $ ProjectR project_handle


getProjectPatronsR :: Text -> Handler Html
getProjectPatronsR project_handle = do
    _ <- requireAuthId

    page <- lookupGetParamDefault "page" 0
    per_page <- lookupGetParamDefault "count" 20

    (project, pledges, user_payouts_map) <- runYDB $ do
        Entity project_id project <- getBy404 $ UniqueProjectHandle project_handle
        pledges <- select $ from $ \ (pledge `InnerJoin` user) -> do
            on_ $ pledge ^. PledgeUser ==. user ^. UserId
            where_ $ pledge ^. PledgeProject ==. val project_id
                &&. pledge ^. PledgeFundedShares >. val 0
            orderBy [ desc (pledge ^. PledgeFundedShares), asc (user ^. UserName), asc (user ^. UserId)]
            offset page
            limit per_page
            return (pledge, user)

        last_paydays <- case projectLastPayday project of
            Nothing -> return []
            Just last_payday -> select $ from $ \ payday -> do
                where_ $ payday ^. PaydayId <=. val last_payday
                orderBy [ desc $ payday ^. PaydayId ]
                limit 2
                return payday

        user_payouts <- select $ from $ \ (transaction `InnerJoin` user) -> do
            where_ $ transaction ^. TransactionPayday `in_` valList (map (Just . entityKey) last_paydays)
            on_ $ transaction ^. TransactionDebit ==. just (user ^. UserAccount)
            groupBy $ user ^. UserId
            return (user ^. UserId, count $ transaction ^. TransactionId)

        return (project, pledges, M.fromList $ map ((\ (Value x :: Value UserId) -> x) *** (\ (Value x :: Value Int) -> x)) user_payouts)

    defaultLayout $ do
        setTitle . toHtml $ projectName project <> " Patrons | Snowdrift.coop"
        $(widgetFile "project_patrons")

getProjectTransactionsR :: Text -> Handler Html
getProjectTransactionsR project_handle = do
    (project, account, account_map, transaction_groups) <- runYDB $ do
        Entity _ project :: Entity Project <- getBy404 $ UniqueProjectHandle project_handle

        account <- get404 $ projectAccount project

        transactions <- select $ from $ \ t -> do
            where_ $ t ^. TransactionCredit ==. val (Just $ projectAccount project)
                    ||. t ^. TransactionDebit ==. val (Just $ projectAccount project)

            orderBy [ desc $ t ^. TransactionTs ]
            return t

        let accounts = S.toList $ S.fromList $ concatMap (\ (Entity _ t) -> maybeToList (transactionCredit t) <> maybeToList (transactionDebit t)) transactions

        users_by_account <- fmap (M.fromList . map (userAccount . entityVal &&& Right)) $ select $ from $ \ u -> do
            where_ $ u ^. UserAccount `in_` valList accounts
            return u

        projects_by_account <- fmap (M.fromList . map (projectAccount . entityVal &&& Left)) $ select $ from $ \ p -> do
            where_ $ p ^. ProjectAccount `in_` valList accounts
            return p

        let account_map = projects_by_account `M.union` users_by_account

        payday_map <- fmap (M.fromList . map (entityKey &&& id)) $ select $ from $ \ pd -> do
            where_ $ pd ^. PaydayId `in_` valList (S.toList $ S.fromList $ mapMaybe (transactionPayday . entityVal) transactions)
            return pd

        return (project, account, account_map, process payday_map transactions)

    let getOtherAccount transaction
            | transactionCredit transaction == Just (projectAccount project) = transactionDebit transaction
            | transactionDebit transaction == Just (projectAccount project) = transactionCredit transaction
            | otherwise = Nothing

    defaultLayout $ do
        setTitle . toHtml $ projectName project <> " Transactions | Snowdrift.coop"
        $(widgetFile "project_transactions")

  where
    process payday_map =
        let process' [] [] = []
            process' (t':ts') [] = [(fmap (payday_map M.!) $ transactionPayday $ entityVal t', reverse (t':ts'))]
            process' [] (t:ts) = process' [t] ts

            process' (t':ts') (t:ts)
                | transactionPayday (entityVal t') == transactionPayday (entityVal t)
                = process' (t:t':ts') ts
                | otherwise
                = (fmap (payday_map M.!) $ transactionPayday $ entityVal t', reverse (t':ts')) : process' [t] ts
         in process' []


getProjectBlogR :: Text -> Handler Html
getProjectBlogR project_handle = do
    maybe_from <- fmap (Key . PersistInt64 . read . T.unpack) <$> lookupGetParam "from"
    post_count <- fromMaybe 10 <$> fmap (read . T.unpack) <$> lookupGetParam "from"
    Entity project_id project <- runYDB $ getBy404 $ UniqueProjectHandle project_handle

    let apply_offset blog = maybe id (\ from_blog rest -> blog ^. ProjectBlogId >=. val from_blog &&. rest) maybe_from

    (posts, next) <- fmap (splitAt post_count) $ runDB $
        select $
        from $ \blog -> do
        where_ $ apply_offset blog $ blog ^. ProjectBlogProject ==. val project_id
        orderBy [ desc $ blog ^. ProjectBlogTime, desc $ blog ^. ProjectBlogId ]
        limit (fromIntegral post_count + 1)
        return blog

    renderRouteParams <- getUrlRenderParams

    let nextRoute next_id = renderRouteParams (ProjectBlogR project_handle) [("from", toPathPiece next_id)]

    defaultLayout $ do
        setTitle . toHtml $ projectName project <> " Blog | Snowdrift.coop"
        $(widgetFile "project_blog")

projectBlogForm :: UTCTime -> UserId -> ProjectId -> Form ProjectBlog
projectBlogForm now user_id project_id =
    renderBootstrap3 $ mkBlog
        <$> areq' textField "Post Title" Nothing
        <*> areq' snowdriftMarkdownField "Post" Nothing
  where
    mkBlog :: Text -> Markdown -> ProjectBlog
    mkBlog title (Markdown content) =
        let (top_content, bottom_content) = break (== "---") $ T.lines content
         in ProjectBlog now title user_id project_id undefined (Markdown $ T.unlines top_content) (if null bottom_content then Nothing else Just $ Markdown $ T.unlines bottom_content)


postProjectBlogR :: Text -> Handler Html
postProjectBlogR project_handle = do
    viewer_id <- requireAuthId

    Entity project_id _ <- runYDB $ do
        can_edit <- or <$> sequence
            [ isProjectAdmin project_handle viewer_id
            , isProjectTeamMember project_handle viewer_id
            , isProjectAdmin "snowdrift" viewer_id
            ]

        if can_edit
         then getBy404 $ UniqueProjectHandle project_handle
         else permissionDenied "You do not have permission to edit this project."

    now <- liftIO getCurrentTime

    ((result, _), _) <- runFormPost $ projectBlogForm now viewer_id project_id

    case result of
        FormSuccess blog_post' -> do
            let blog_post :: ProjectBlog
                blog_post = blog_post' { projectBlogTime = now, projectBlogUser = viewer_id }
            mode <- lookupPostParam "mode"
            let action :: Text = "post"
            case mode of
                Just "preview" -> do

                    (form, _) <- generateFormPost $ projectBlogForm now viewer_id project_id

                    defaultLayout $ previewWidget form action $ renderBlogPost project_handle blog_post

                Just x | x == action -> do
                    void $ runDB $ insert blog_post
                    addAlert "success" "posted"
                    redirect $ ProjectR project_handle

                _ -> do
                    addAlertEm "danger" "unrecognized mode" "Error: "
                    redirect $ ProjectR project_handle

        x -> do
            addAlert "danger" $ T.pack $ show x
            redirect $ ProjectR project_handle


getProjectBlogPostR :: Text -> ProjectBlogId -> Handler Html
getProjectBlogPostR project_handle blog_post_id = do
    (Entity _ project, blog_post) <- runYDB $ (,)
        <$> getBy404 (UniqueProjectHandle project_handle)
        <*> get404 blog_post_id

    defaultLayout $ do
        setTitle . toHtml $ projectName project <> " Blog - " <> projectBlogTitle blog_post <> " | Snowdrift.coop"
        renderBlogPost project_handle blog_post


renderBlogPost :: Text -> ProjectBlog -> WidgetT App IO ()
renderBlogPost project_handle blog_post = do
    let (Markdown top_content) = projectBlogTopContent blog_post
        (Markdown bottom_content) = fromMaybe (Markdown "") $ projectBlogBottomContent blog_post
        title = projectBlogTitle blog_post
        content = markdownWidget project_handle $ Markdown $ T.snoc top_content '\n' <> bottom_content

    $(widgetFile "blog_post")

postWatchProjectR :: ProjectId -> Handler ()
postWatchProjectR = undefined -- TODO(mitchell)

postUnwatchProjectR :: ProjectId -> Handler ()
postUnwatchProjectR = undefined -- TODO(mitchell)

--------------------------------------------------------------------------------
-- /feed

-- Analogous data types to SnowdriftEvent, but specialized for displaying the feed.
-- This is necessary because there is some extra information required for displaying
-- feed items not present in SnowdriftEvents, such as the WikiPage that a Comment
-- was made on.
data FeedEvent = FeedEvent UTCTime FeedEventData
    deriving Eq

data FeedEventData
    = FECommentPostedOnWikiPage (Entity Comment) (Entity WikiPage)
    | FEWikiEdit (Entity WikiEdit) (Entity WikiPage)
    deriving Eq

-- | Order FeedEvents by reverse timestamp (newer comes first).
instance Ord FeedEvent where
    compare (FeedEvent time1 _) (FeedEvent time2 _) = compare time2 time1

-- | If an unapproved comment is passed to this function, bad things will happen.
mkCommentPostedOnWikiPageFeedEvent :: Entity Comment -> Entity WikiPage -> FeedEvent
mkCommentPostedOnWikiPageFeedEvent c@(Entity _ Comment{..}) wp =
    FeedEvent (fromJust commentModeratedTs) (FECommentPostedOnWikiPage c wp)

mkWikiEditFeedEvent :: Entity WikiEdit -> Entity WikiPage -> FeedEvent
mkWikiEditFeedEvent we@(Entity _ WikiEdit{..}) wp = FeedEvent wikiEditTs (FEWikiEdit we wp)

-- | This function is responsible for hitting every relevant event table. Nothing
-- statically guarantees that.
getProjectFeedR :: Text -> Handler Html
getProjectFeedR project_handle = do
    before <- maybe (liftIO getCurrentTime) (return . read . T.unpack) =<< lookupGetParam "before"
    events <- runYDB $ do
        Entity project_id _ <- getBy404 (UniqueProjectHandle project_handle)
        comments_posted <- map (uncurry mkCommentPostedOnWikiPageFeedEvent) <$> fetchProjectCommentsPostedOnWikiPagesDB project_id before
        wiki_edits      <- map (uncurry mkWikiEditFeedEvent)                <$> fetchProjectWikiEditsDB                 project_id before
        return (sort $ comments_posted ++ wiki_edits)
    defaultLayout $(widgetFile "project_feed")
