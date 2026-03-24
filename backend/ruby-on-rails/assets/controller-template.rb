# RESTful Controller Template
#
# Features: strong params, error handling, Pundit authorization,
# Turbo Stream responses, pagination, format negotiation.
#
# Place in: app/controllers/<name>_controller.rb

class ArticlesController < ApplicationController
  # ── Callbacks ───────────────────────────────────────────────────────────────
  before_action :authenticate_user!, except: %i[index show]
  before_action :set_article, only: %i[show edit update destroy]
  after_action  :verify_authorized, except: %i[index]

  # ── Actions ─────────────────────────────────────────────────────────────────

  # GET /articles
  def index
    @pagy, @articles = pagy(
      policy_scope(Article)
        .includes(:author, :category, :tags)
        .published
        .recent,
      items: 20
    )

    respond_to do |format|
      format.html
      format.json { render json: @articles }
    end
  end

  # GET /articles/:id
  def show
    authorize @article

    respond_to do |format|
      format.html
      format.json { render json: @article }
    end
  end

  # GET /articles/new
  def new
    @article = current_user.articles.build
    authorize @article
  end

  # POST /articles
  def create
    @article = current_user.articles.build(article_params)
    authorize @article

    if @article.save
      respond_to do |format|
        format.html { redirect_to @article, notice: "Article was created." }
        format.turbo_stream { flash.now[:notice] = "Article was created." }
        format.json { render json: @article, status: :created, location: @article }
      end
    else
      respond_to do |format|
        format.html { render :new, status: :unprocessable_entity }
        format.turbo_stream { render :form_errors, status: :unprocessable_entity }
        format.json { render json: { errors: @article.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  # GET /articles/:id/edit
  def edit
    authorize @article
  end

  # PATCH/PUT /articles/:id
  def update
    authorize @article

    if @article.update(article_params)
      respond_to do |format|
        format.html { redirect_to @article, notice: "Article was updated." }
        format.turbo_stream { flash.now[:notice] = "Article was updated." }
        format.json { render json: @article }
      end
    else
      respond_to do |format|
        format.html { render :edit, status: :unprocessable_entity }
        format.turbo_stream { render :form_errors, status: :unprocessable_entity }
        format.json { render json: { errors: @article.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /articles/:id
  def destroy
    authorize @article
    @article.destroy!

    respond_to do |format|
      format.html { redirect_to articles_path, notice: "Article was deleted.", status: :see_other }
      format.turbo_stream { flash.now[:notice] = "Article was deleted." }
      format.json { head :no_content }
    end
  end

  private

  # ── Strong Parameters ───────────────────────────────────────────────────────
  def article_params
    # Rails 8: params.expect (safer than params.require.permit)
    params.expect(article: [
      :title, :body, :excerpt, :category_id,
      :published, :featured, :cover_image,
      tag_ids: [], documents: []
    ])
  end

  # ── Finders ─────────────────────────────────────────────────────────────────
  def set_article
    @article = Article.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    respond_to do |format|
      format.html { redirect_to articles_path, alert: "Article not found." }
      format.json { render json: { error: "Not found" }, status: :not_found }
    end
  end
end
