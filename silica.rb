# -*- coding: utf-8 -*-
require 'pai.rb'
require 'protocol.rb'
require 'util.rb'

require 'use_mjai_component.rb'
require 'tehai.rb'
require 'score.rb'
require 'yama.rb'
require 'furiten_checker.rb'
require 'dojun_checker.rb'
require 'pai_count.rb'
require 'yakuhai.rb'
require 'dora.rb'
require 'silica_stats.rb'
require 'pais.rb'
require 'silica_risk_estimate.rb'
require 'silica_eval_info.rb'
require 'silica_heuristics.rb'
require 'reach_others.rb'
require 'progress.rb'
require 'kuikae.rb'

class Silica < UseMjaiComponent

  def initialize(name, room)
    super()

    @name = name
    @room = room

    @tehai     = add_component(Tehai.new)
    @scores    = add_component(Score.new)
    @yama      = add_component(Yama.new)
    @furiten   = add_component(FuritenChecker.new)
    @dojun     = add_component(DojunChecker.new)
    @pai_count = add_component(PaiCount.new)
    @yakuhai   = add_component(Yakuhai.new)
    @reach     = add_component(Reach.new)
    @dora      = add_component(Dora.new)
    @furo      = add_component(Furo.new)
    @risk      = add_component(SilicaRiskEstimate.new)
    @reach_others = add_component(ReachOthers.new)
    @progress  = add_component(Progress.new)
    @kuikae    = add_component(KuikaeChecker.new)

    add_component(SilicaStats.new)

  end

  def hello(action)
    super
    Action::join(@name, @room)
  end

  def start_game(action)
    super
    @id = action['id']
    Action::none()
  end

  def start_kyoku(action)
    super
    Action::none()
  end

  def yakuari
    yaku_anko = Pais.JIHAIS.any? do |pai|
      @yakuhai.check(pai) && @tehai.count(pai) >= 3
    end

    yaku_naki = @furo.any? do |f|
      f[:type] != :chi && @yakuhai.check(f[:consumed][0])
    end

    yaku_anko || yaku_naki
  end

  def menzen
    @furo.empty?
  end

  def mask
    if menzen
      Shanten::NORMAL | Shanten::CHITOI
    else
      Shanten::NORMAL
    end
  end

  def should_ori
    @reach_others.check && (@tehai.shanten(yakuari || menzen, mask) > 0 || @furiten.check(@tehai))
  end

  def what_to_discard(tsumo_pai)

    cs = @tehai.select{|pai|!@kuikae.check(pai)}.map do |pai|
      SilicaEvalInfo.new(
        pai,
        @tehai.shanten_removed(pai, yakuari || menzen, mask),
        @tehai.ukeire_removed(@pai_count, pai, yakuari || menzen, mask),
        (-1) * SilicaHeuristics::pai_point(pai, @yakuhai, @dora),
        @risk.estimate(pai)
      )
    end

    cs.each do |e|
      $stderr.puts e.to_s
    end
    
    if should_ori
      cs.max_by{|c| c.risk * (-1000000) + c.to_i}.pai
    else
      cs.max_by{|c| c.to_i}.pai
    end
    
  end

  # silica#discard
  # 切るものがwhat_to_discardで返ってきて、リーチするかを決めてActionを返す。

  def discard(pai)

    d_pai = what_to_discard(pai)

    $stderr.puts "tehai: = #{@tehai.to_s}"
    $stderr.puts "selected_pai = #{d_pai}"
    $stderr.puts "shanten = #{@tehai.shanten_removed(d_pai, true, mask)}"
    $stderr.puts "@id = #{@id}"

    $stderr.puts "@furo.empty? = #{@furo.empty?}"
    $stderr.puts "@yama.length = #{@yama.length}"

    if @furo.empty? && @yama.length >= 4 && @scores[@id] >= 1000 && @tehai.shanten_removed(d_pai, true, mask) == 0
      @reach_pending = Action::dahai(@id, d_pai, d_pai == pai)
      Action::reach(@id)
    else
      Action::dahai(@id, d_pai, d_pai == pai)
    end    
  end

  # silica#can_agari
  # trueなら絶対役あり
  def can_agari(pai)
    tanyao = (!pai.yaochu?) && @tehai.all?{|p|!p.yaochu?} && @furo.all?{|f|(!f[:pai].yaochu?) && f[:consumed].all?{|p|!p.yaochu?}}
    $stderr.puts "yakuari = #{yakuari}"
    $stderr.puts "reach   = #{@reach.check}"
    $stderr.puts "tanyao  = #{tanyao}"
    yakuari || @reach.check || tanyao
  end

  # silica#tsumo
  # 自分以外のツモなら、何もしない
  # 和了れるなら和了る
  # リーチしている場合はツモ切り
  # その他の場合はdiscard関数へ

  def tsumo(action) # fixed
    super
    pai = Pai.parse(action['pai'])
    if action['actor'] == @id
      if @tehai.shanten(true, mask) == -1 && can_agari(pai)
        Action::hora(@id, @id, pai)
      elsif @reach.check
        Action::dahai(@id, pai, true) # この時点では手牌から取り除かない
      else 
        discard(pai)
      end
    else
      Action::none()
    end
  end

  # silica#eval_try_meld
  # 鳴いてみて評価する
  # これは役牌ポンには使わないのでyakuariはこれでOK
  #

  def eval_meld_discard(md)
    SilicaEvalInfo.new(
      md.discard,
      @tehai.shanten_list_removed(md.consumed_discard, yakuari || @yakuhai.check(md.discard), Shanten::NORMAL),
      @tehai.ukeire_list_removed(@pai_count, md.consumed_discard, yakuari || @yakuhai.check(md.discard), Shanten::NORMAL),
      0,
      @risk.estimate(md.discard)
    )
  end

  # silica#dahai
  # 自分の打牌なら、なにもしない
  # もしロンできるならする
  # 自分がリーチしてるまたは山が0枚の場合はスルー
  # 自分以外の誰かがリーチしていて、自分が聴牌してない場合はオリ(スルー)
  # 役牌対子が鳴けるなら鳴く
  # 以上どれにも当てはまらない場合は、鳴きをスルー含めて列挙して、一番良さそうなのを選ぶ

  def dahai(action)
    super
    pai = Pai.parse(action['pai'])
    actor = action['actor']
    if actor == @id
      Action::none()
    else
      if @tehai.shanten_added(pai, true, mask) == -1 && can_agari(pai) && !@furiten.check(@tehai) && !@dojun.check
        Action::hora(@id, actor, pai.to_s) # ロン
      else
        if @reach.check || @yama.length == 0 # ルール上鳴けない
          Action::none()
        elsif @reach_others.check # リーチを受けてる時は鳴かない
          Action::none()
        else # 全列挙して比較する
          alternatives = 
            @tehai.list_naki_dahai(pai, (@id - actor + 4) % 4 == 1).select do |meld|
              yakuari || @yakuhai.check(pai) || meld.all?{|p|!p.yaochu?}
            end
          alternatives << MeldDiscard::None

          $stderr.puts alternatives.to_s

          sel = alternatives.max_by do |md|
            if md.type == :none
              SilicaEvalInfo.new(nil, @tehai.shanten(yakuari || menzen, mask), @tehai.ukeire(@pai_count, yakuari || menzen, mask), 50, 5).to_i # TODO: FIXME: 5 is hyper-tenuki
            else
              eval_meld_discard(md).to_i
            end
          end
          
          case sel.type
            when :none
              Action::none()
            when :pon
              Action::pon(@id, actor, pai, sel.consumed)
            when :chi
              Action::chi(@id, actor, pai, sel.consumed)
            when :daiminkan
              Action::daiminkan(@id, actor, pai, sel.consumed)
            else
              raise "assertion: ai#dahai: naki_type is invalid."
          end
        end
      end
    end
  end

  # silica#reach
  # 自分なら、決めておいた行動をする
  # それ以外なら何もしない

  def reach(action)
    super
    actor = action['actor']
    if actor == @id then
      @reach_pending
    else
      Action::none()
    end
  end

  def reach_accepted(action)
    super
    Action::none()
  end

  # silica#pon
  # 自分ならdiscard
  # それ以外なら何もしない

  def pon(action)
    super
    if action['actor'] == @id then
      discard(nil)
    else
      Action::none()
    end
  end

  # silica#chi
  # 自分ならdiscard
  # それ以外なら何もしない

  def chi(action)
    super
    if action['actor'] == @id then
      discard(nil)
    else
      Action::none()
    end
  end

  def hora(action)
    super
    Action::none()
  end

  def ryukyoku(action)
    super
    Action::none()
  end

  def end_kyoku(action)
    super
    Action::none()
  end
  
  def end_game(action)
    super
    Action::none()
  end

  def dora(action)
    super
    Action::none()
  end

  # silica#dump
  # デバッグ用

  def dump(f)
    f.puts "id: #{@id}"
    f.puts "#{@progress.kyoku}局#{@progress.honba}本場"
    f.puts "#{@scores}"
    f.puts "リーチ: #{@reach.check}"
    f.puts "場風: #{@yakuhai.bakaze}"
    f.puts "自風: #{@yakuhai.jikaze}"
    f.puts "ドラ: #{@dora}"
    f.puts "手牌: #{@tehai}"
    f.puts "副露: #{@furo}"
    f.puts "残り山: #{@yama.length}"
  end

end
