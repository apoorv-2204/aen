defmodule UnirisCore.ReleaseTasks.HostWebsiteUniris do
  @moduledoc """
  Example of content hosting transaction to provide content delivery.
  This is the on chain transactions of the uniris.io website hosting
  """

  alias UnirisCore.Transaction
  alias UnirisCore.TransactionData

  defp assets_seeds() do
    %{
    Application.app_dir(:uniris_core, "priv/uniris.io/animate.css") => "animate_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/bicon.css") => "bicon_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/bootstrap.min.css") => "bootstrap_css_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/bootstrap.min.js") => "bootstrap_js_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/font-awesome.css") => "fontawesome_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/carousel.css") => "carousel_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/jquery.min.js") => "jquery_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/magnific-popup.css") => "magnificpopup_css_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/main.css") => "uniris_css_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/owl.carousel.min.css") => "owlcarousel_css_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/owl.carousel.min.js") => "owlcarousel_js_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/popper.min.js") => "popper_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/wow.min.js") => "wow_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/jquery.countdown.min.js") => "jquerycountdown_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/jquery.magnificpopup.min.js") => "magnificpopup_js_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/particles.js") => "particles_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/main.js") => "uniris_js_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/d3.min.js") => "d3_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/d3.queue.min.js") => "d3queue_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/d3_topo_json.min.js") => "d3topojson_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/biometric_animation.js") => "uniris_biometricanim_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/blockchain_animation.js") => "uniris_blockchainanim_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/form_validator.min.js") => "formvalidator_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/logo_uniris.svg") => "uniris_logo_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/banner_curve.svg") => "banner_curve_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/jo2024.svg") => "jo2024_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/polytechnique.png") => "polytechnique_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/hec.png") => "hec_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/stationf.png") => "stationf_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/gicat.png") => "gicat_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/bpi.png") => "bpi_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/uniris_token_split.svg") => "uniris_token_split_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/uniris_token_growth.svg") => "uniris_token_growth_seed",
    Application.app_dir(:uniris_core, "priv/uniris.io/index.html") => "uniris_index_seed",
  }
  end


  def run() do
    Enum.map(assets_seeds(), fn {file, seed} ->
      content = File.read!(file)
      tx =
        Transaction.new(
          :hosting,
          %TransactionData{
            content: content
          },
          seed,
          0
        )

      UnirisCore.send_new_transaction(tx)
      {file, Base.encode16(tx.address)}
    end)
  end
end
