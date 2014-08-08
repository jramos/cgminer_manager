module ApplicationHelper
  def format_hashrate(rate)
    rate = rate.to_f
    unit = 'H/s'

    if (rate >= 1000)
      rate /= 1000; unit = 'KH/s'
    end

    if(rate >= 1000)
      rate /= 1000; unit = 'MH/s'
    end

    if(rate >= 1000)
      rate /= 1000; unit = 'GH/s'
    end

    if(rate >= 1000)
      rate /= 1000; unit = 'TH/s'
    end

    if(rate >= 1000)
      rate /= 1000; unit = 'PH/s'
    end

    if(rate >= 1000)
      rate /= 1000; unit = 'EH/s'
    end

    if(rate >= 1000)
      rate /= 1000; unit = 'ZH/s'
    end

    if(rate >= 1000)
      rate /= 1000; unit = 'YH/s'
    end

    return (rate.round(2).to_s + ' ' + unit);
  end

  def format_bytes(bytes)
    rate = bytes.to_i
    unit = 'B'

    if (rate >= 1000)
      rate /= 1000; unit = 'KB'
    end

    if(rate >= 1000)
      rate /= 1000; unit = 'MB'
    end

    if(rate >= 1000)
      rate /= 1000; unit = 'GB'
    end

    if(rate >= 1000)
      rate /= 1000; unit = 'TB'
    end

    if(rate >= 1000)
      rate /= 1000; unit = 'PB'
    end

    return (rate.round(2).to_s + ' ' + unit);
  end

  def to_ferinheight(centigrade)
    (1.8 * centigrade.to_f + 32).round(1)
  end

  def is_multi_command?
    !!params[:command].match('\+')
  end
end
